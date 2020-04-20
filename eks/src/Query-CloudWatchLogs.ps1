#Requires -Module @{ ModuleName = 'AWSPowerShell.NetCore'; ModuleVersion = '4.0.0' }

<#
Consider uploading all json files in path (retry)
Edgecases regarding query intervals and +/- 1 second
#>

[CmdletBinding()]
param (

    [Parameter()]
    [string]
    $AwsProfile,

    [Parameter(Mandatory)]
    [string]
    $AwsRegion,

    [Parameter()]
    [string]
    $LogGroupName,

    [Parameter()]
    [string]
    $LogStreamNamePrefix,

    [Parameter()]
    [Int16]
    $QueryIntervalHours = 7 * 24 - 1, # 1 week minus one hour

    [Parameter()]
    [int16]
    $QueryRetrySeconds = 10,

    [Parameter()]
    [int32]
    $QueryChunkSeconds = 2 * 7 * 24 * 60 * 60, # 2 weeks

    [Parameter()]
    [int16]
    $IntervalWaitMinutes = 60,

    [Parameter(Mandatory)]
    [string]
    $S3BucketName,

    [Parameter()]
    [string]
    $S3Path,

    [switch]
    $LocalExec

)

Begin {

    # Include
    if ($PSScriptRoot) {
        $ScriptRoot = $PSScriptRoot
    } else {
        $ScriptRoot = './'
    }
    . (Join-Path $ScriptRoot 'include.ps1')

    # Define "constants"
    $ErrorActionPreference = "Stop"
    $ProgressPreference = "SilentlyContinue" # do no show progress bars
    $OutputFileNamePrefix = $LogStreamNamePrefix -replace "-$", "" # remove trailing dash if present
    $OutputFileNameExt = "json"
    $OutputContentType = "application/json"
    $LastQueryFileName = "${OutputFileNamePrefix}_LastQueryTime.txt"
    $LastQueryFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath $LastQueryFileName
    $LastQueryS3Key = "$S3Path/$LastQueryFileName"

    # Local execution?
    If ($LocalExec) {
        $IntervalWaitMinutes = 1/6
        $QueryIntervalHours  = 1/60
    }

    # Set AWS profile and region
    Set-DefaultAWSRegion -Region $AwsRegion
    If ($AwsProfile) {    
        Set-AWSCredential -ProfileName $AwsProfile
    }

}

Process {

    While ($true) {

        # Get basic info on log group
        $LogGroup = Get-CWLLogGroup -LogGroupNamePrefix $LogGroupName | Where-Object {$_.LogGroupName -eq $LogGroupName}
        $LogGroupStartTime = $LogGroup.CreationTime
        $LogGroupStartTimeUnix = [math]::Round((Get-DateTime -Date $LogGroupStartTime).UnixTime)

        # Determine query start time
        Write-Host "Getting last query time from s3://$S3BucketName/$LastQueryS3Key"
        Remove-Item $LastQueryFile -ErrorAction SilentlyContinue | Out-Null
        Try {
            Read-S3Object -BucketName $S3BucketName -Key $LastQueryS3Key -File $LastQueryFile | Out-Null
            [int64]$QueryStartTimeUnix = Get-Content $LastQueryFile -ErrorAction Stop | Select-Object -First 1
        }
        Catch { 
            Write-Host "No file found for last query, defaulting to creation time of log group ($LogGroupStartTime)"
            [int64]$QueryStartTimeUnix = $LogGroupStartTimeUnix
        }
        $QueryStartTime = (Get-DateTime -UnixTime $QueryStartTimeUnix).DateTimeUTC
        $QueryStartTimestamp = (Get-DateTime -UnixTime $QueryStartTimeUnix).TimeStampUTC

        # Determine query end time
        $QueryEndTime = Get-Date
        $QueryEndTimeUnix = [math]::Round((Get-DateTime -Date $QueryEndTime).UnixTime)
        $QueryEndTimestamp = (Get-DateTime -Date $QueryEndTime).TimeStampUTC
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
            $QueryChunkStartTime = (Get-DateTime -UnixTime $QueryChunk.StartTime).DateTimeUTC
            $QueryChunkEndTime = (Get-DateTime -UnixTime $QueryChunk.EndTime).DateTimeUTC
            Write-Host "Querying '$LogGroupName' for events between $((Get-DateTime -Date $QueryChunkStartTime).ISOSortableUTC) and $((Get-DateTime -Date $QueryChunkEndTime).ISOSortableUTC)"
            $QueryString = @"
fields @timestamp, verb, objectRef.resource, objectRef.namespace, objectRef.name
| filter @logStream like "$LogStreamNamePrefix" and verb = "create" and objectRef.resource = "replicasets" and responseStatus.code like /2\d\d/
| sort @timestamp
"@
            $QueryArgs = @{
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
                Write-Host "Waiting for query '$QueryId' ($((Get-DateTime).ISOSortableUTC))"
                Try { $Query = Get-CWLQuery -ErrorAction Stop | Where-Object { $_.QueryId -eq $QueryId } }
                Catch { Write-Warning "$($_.Exception.Message)" }
                Start-Sleep 10
            } While ($Query.Status -eq "Running")

            # Fetch and parse results
            $QueryResult = Get-CWLQueryResult -QueryId $QueryId
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
        Write-S3Object -BucketName $S3BucketName -Key $LastQueryS3Key -Content $QueryEndTimeUnix

        # Upload to S3
        If (Test-Path $OutputFilePath -PathType Leaf) {
            $S3Key = "$S3Path/$OutputFileName"
            Write-Host "Uploading '$OutputFileName' to s3://$S3BucketName/$S3Key"
            Write-S3Object -BucketName $S3BucketName -Key $S3Key -File $OutputFilePath -ContentType $OutputContentType
            If (!($LocalExec)) {
                Remove-Item $OutputFilePath
            }
        }

        # Wait until next interval
        $NextQueryTime = $QueryEndTime + (New-TimeSpan -Hours $QueryIntervalHours)
        Do {
            Write-Host "Waiting until $NextQueryTime before next query ($((Get-DateTime).ISOSortableUTC))"
            Start-Sleep -Seconds ($IntervalWaitMinutes * 60)
        } Until ((Get-Date) -ge $NextQueryTime)

    }

}