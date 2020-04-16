#Requires -Module @{ ModuleName = 'AWSPowerShell.NetCore'; ModuleVersion = '4.0.0' }

<#
KIAM vs. local execution
Consider uploading all json files in path (retry)
Edgecases regarding query intervals and +/- 1 second
#>

[CmdletBinding()]
param (

    [Parameter(Mandatory)]
    [string]
    $AwsProfile,

    [Parameter()]
    [string]
    $AwsRegion = 'eu-west-1',

    [Parameter()]
    [string]
    $LogGroupName = "/aws/eks/hellman/cluster",

    [Parameter()]
    [string]
    $LogStreamNamePrefix = "kube-apiserver-audit-",

    [Parameter()]
    [Int16]
    $QueryIntervalHours = 7 * 24,

    [Parameter()]
    [string]
    $S3BucketName = "dfds-datalake",

    [Parameter()]
    [string]
    $S3Path = "aws/eks",

    [switch]
    $LocalExec

)

Begin {

    # Define "constants"
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue" # do no show progress bars
    $Epoch = Get-Date "1970-01-01"
    $OutputFileNamePrefix = $LogStreamNamePrefix -replace "-$", "" # remove trailing dash if present
    $OutputFileNameExt = "json"
    $OutputContentType = "application/json"
    $QueryRetrySeconds = 10
    $QueryChunkSeconds = 1209600 # 2 weeks
    $IntervalWaitSeconds = 300
    $LastQueryFileName = "${OutputFileNamePrefix}_LastQueryTime.txt"
    $LastQueryFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath $LastQueryFileName
    $LastQueryS3Key = "$S3Path/$LastQueryFileName"

    # Local execution?
    If ($LocalExec) {
        $IntervalWaitSeconds = 10
        $QueryIntervalHours = 1/60
    }

}

Process {

    While ($true) {

        # Get basic info on log group
        $LogGroup = Get-CWLLogGroup -ProfileName $AwsProfile -Region $AwsRegion -LogGroupNamePrefix $LogGroupName | Where-Object {$_.LogGroupName -eq $LogGroupName}
        $LogGroupStartTime = $LogGroup.CreationTime
        $LogGroupStartTimeUnix = [math]::Round(($LogGroupStartTime - $Epoch | Select-Object -Expand TotalSeconds))

        # Determine query start time
        Write-Host "Getting last query time from s3://$S3BucketName/$LastQueryS3Key"
        Remove-Item $LastQueryFile -ErrorAction SilentlyContinue | Out-Null
        Try {
            Read-S3Object -AWSProfileName $AwsProfile -Region $AwsRegion -BucketName $S3BucketName -Key $LastQueryS3Key -File $LastQueryFile | Out-Null
            [int64]$QueryStartTimeUnix = Get-Content $LastQueryFile -ErrorAction Stop | Select-Object -First 1
        }
        Catch { 
            Write-Host "No file found for last query, defaulting to creation time of log group ($LogGroupStartTime)"
            [int64]$QueryStartTimeUnix = $LogGroupStartTimeUnix
        }
        $QueryStartTime = ([datetimeoffset]::FromUnixTimeSeconds($QueryStartTimeUnix)).DateTime
        $QueryStartTimestamp = Get-Date $QueryStartTime -Format "yyyyMMdd-HHmmss"

        # Determine query end time
        $QueryEndTime = Get-Date
        [int64]$QueryEndTimeUnix = [math]::Round(($QueryEndTime - $Epoch | Select-Object -Expand TotalSeconds))
        $QueryEndTimestamp = Get-Date $QueryEndTime -Format "yyyyMMdd-HHmmss"
        $QueryTimeDiff = $QueryEndTimeUnix - $QueryStartTimeUnix

        # Determine output file name and path
        # Use unix start end time in filename?
        $OutputFileName = "${OutputFileNamePrefix}_${QueryStartTimestamp}_${QueryEndTimestamp}.${OutputFileNameExt}"
        $OutputFilePath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath $OutputFileName

        # Partition query into chunks, to avoid query timeout and hitting result limit of 10.000 per query
        $QueryChunkNumber = [math]::Ceiling($QueryTimeDiff / $QueryChunkSeconds)

        $QueryChunks = For ($i = 0; $i -lt $QueryChunkNumber; $i++) {
            $StartTime = $QueryStartTimeUnix + ($i * $QueryChunkSeconds) + 1
            $EndTime = $QueryStartTimeUnix + (($i + 1) * $QueryChunkSeconds)
            if ($EndTime -gt $QueryEndTimeUnix) {
                $EndTime = $QueryEndTimeUnix
            }
            [pscustomobject]@{
                StartTime = $StartTime
                EndTime = $EndTime
            }
        }

        # ----- Begin logstream loop -----
        ForEach ($QueryChunk in $QueryChunks) {

            # Start query
            $QueryChunkStartTime = ([datetimeoffset]::FromUnixTimeSeconds($QueryChunk.StartTime)).DateTime
            $QueryChunkEndTime = ([datetimeoffset]::FromUnixTimeSeconds($QueryChunk.EndTime)).DateTime
            Write-Host "Querying '$LogGroupName' for events between $QueryChunkStartTime and $QueryChunkEndTime"
            $QueryString = @"
fields @timestamp, verb, objectRef.resource, objectRef.namespace, objectRef.name
| filter @logStream like "$LogStreamNamePrefix" and verb = "create" and objectRef.resource = "replicasets" and responseStatus.code like /2\d\d/
| sort @timestamp
"@
            $QueryArgs = @{
                ProfileName  = $AwsProfile
                Region       = $AwsRegion
                LogGroupName = $LogGroupName
                QueryString  = $QueryString
                StartTime    = $QueryChunk.StartTime
                EndTime      = $QueryChunk.EndTime
                Limit        = 10000
            }
            Try { $QueryId = Start-CWLQuery @QueryArgs -ErrorAction Stop }
            Catch {
                Write-Warning "Query failed: $($_.Exception.Message)`nRetrying in $QueryRetrySeconds seconds"
                Start-Sleep $QueryRetrySeconds
                Continue
            }

            # Wait for query to finish
            Do {
                Write-Host "Waiting for query '$QueryId' ($(Get-Date))"
                Try { $Query = Get-CWLQuery -ProfileName $AwsProfile -Region $AwsRegion -ErrorAction Stop | Where-Object { $_.QueryId -eq $QueryId } }
                Catch { Write-Warning "$($_.Exception.Message)" }
                Start-Sleep 10
            } While ($Query.Status -eq "Running")

            # Fetch and parse results
            $QueryResult = Get-CWLQueryResult -ProfileName $AwsProfile -Region $AwsRegion -QueryId $QueryId
            $ContentKB = [math]::Round($QueryResult.ContentLength / 1KB)
            $ScannedMB = [math]::Round($QueryResult.Statistics.BytesScanned / 1MB)
            $RecordsScanned = $QueryResult.Statistics.RecordsScanned
            $RecordsMatched = $QueryResult.Statistics.RecordsMatched
            Write-Host "$RecordsMatched records matched (${ContentKB} kB) out of $RecordsScanned scanned (${ScannedMB} MB)"
            $ParsedResults = ForEach ($Result in $QueryResult.Results) {
                [pscustomobject]@{
                    timestamp       = $Result | Where-Object { $_.Field -eq '@timestamp' } | Select-Object -Expand Value
                    verb            = $Result | Where-Object { $_.Field -eq 'verb' } | Select-Object -Expand Value
                    objectResource  = $Result | Where-Object { $_.Field -eq 'objectRef.resource' } | Select-Object -Expand Value
                    objectNamespace = $Result | Where-Object { $_.Field -eq 'objectRef.namespace' } | Select-Object -Expand Value
                    objectName      = $Result | Where-Object { $_.Field -eq 'objectRef.name' } | Select-Object -Expand Value
                }
            }

            # Save parsed results to file
            If ($ParsedResults.Count -gt 0) {
                Write-Host "Saving $($ParsedResults.Count) results to '$OutputFilePath'"
                $ParsedResults | ForEach-Object { $_ | ConvertTo-Json -Compress } | Out-File $OutputFilePath -Append
            }

        }
        # ----- End logstream loop -----

        # Save query time
        Write-S3Object -AWSProfileName $AwsProfile -Region $AwsRegion -BucketName $S3BucketName -Key $LastQueryS3Key -Content $QueryEndTimeUnix

        # Upload to S3
        If (Test-Path $OutputFilePath -PathType Leaf) {
            $S3Key = "$S3Path/$OutputFileName"
            Write-Host "Uploading '$OutputFileName' to s3://$S3BucketName/$S3Key"
            Write-S3Object -ProfileName $AwsProfile -Region $AwsRegion -BucketName $S3BucketName -Key $S3Key -File $OutputFilePath -ContentType $OutputContentType
            If (!($LocalExec)) {
                Remove-Item $OutputFilePath
            }
        }

        # Wait until next interval
        $NextQueryTime = $QueryEndTime + (New-TimeSpan -Hours $QueryIntervalHours)
        Do {
            Write-Host "Waiting until $NextQueryTime before next query"
            Start-Sleep -Seconds $IntervalWaitSeconds
        } Until ((Get-Date) -ge $NextQueryTime)

    }

}