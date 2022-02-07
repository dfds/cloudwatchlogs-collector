#Requires -Module @{ ModuleName = 'AWS.Tools.CloudWatchLogs'; ModuleVersion = '4.1.0' }
#Requires -Module @{ ModuleName = 'AWS.Tools.S3'; ModuleVersion = '4.1.0' }
#Requires -Module @{ ModuleName = 'AWS.Tools.SecurityToken'; ModuleVersion = '4.1.0' }

<#

.SYNOPSIS
    Continuously running Powershell Core script for collecting CloudWatch Logs and storing them in S3.

.DESCRIPTION
    Queries for larger timespans than the defined threshold, are broken down into smaller chunks. This is to avoid query timeouts and exceeding the 10000 result cap per query. Query results are filtered, transformed and stored in the specified S3 bucket. The script will then sleep according to the defined query interval, after which the process is repeated.

.EXAMPLE
    ./Query-CloudWatchLogs.ps1 -AwsRegion eu-west-1 -LogGroupName /aws/eks/clustername/cluster -LogStreamNamePrefix kube-apiserver-audit- -S3BucketName
datalake-bucket -S3Path aws/eks -QueryIntervalHours 12

.EXAMPLE
    ./Query-CloudWatchLogs.ps1 -AwsRegion eu-west-1 -LogGroupName /aws/eks/clustername/cluster -LogStreamNamePrefix kube-apiserver-audit- -S3BucketName datalake-bucket -S3Path aws/eks -DevelopmentMode -AwsProfile logging-orgrole

.NOTES
    Consider uploading all json files in path (retry)
    Edgecases regarding query intervals and +/- 1 second
    Split operations into function, for greater overview

.LINK
    https://github.com/dfds/cloudwatchlogs-collector
    https://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html#pstools-cred-provider-chain
    https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html

#>

[CmdletBinding()]
param (

    # Name of the AWS profile to use for authentication. If not specified, the normal credential search order is used.
    [Parameter()]
    [string]
    $AwsProfile,

    # AWS region where the CloudWatch Logs and target S3 bucket reside, e.g. 'eu-west-1'.
    [Parameter(Mandatory)]
    [string]
    $AwsRegion,

    # Name of the CloudWatch Logs log group to query. By default, AWS EKS will log to a log group named '/aws/eks/${clustername}/cluster'.
    [Parameter()]
    [string]
    $LogGroupName,

    # Part of the log stream names to be included as a filter in the CloudWatch Logs query.
    [Parameter()]
    [string]
    $LogStreamNamePrefix,

    # Interval at which queries will be executed. The script will sleep in-between.
    [Parameter()]
    [Int16]
    $QueryIntervalHours = 7 * 24 - 1, # 1 week minus one hour

    # How long to sleep, before retrying failed queries.
    [Parameter()]
    [int16]
    $QueryRetrySeconds = 10,

    # The timespan length to break down queries into.
    [Parameter()]
    [int16]
    $QueryChunkDays = 14,

    # The interval at which to check if query interval has passed
    [Parameter()]
    [int16]
    $IntervalWaitMinutes = 60,

    # The S3 bucket the output file is uploaded to.                                                                                        |
    [Parameter(Mandatory)]
    [string]
    $S3BucketName,

    # The path (or directory) in the S3 bucket to store the output file.
    [Parameter()]
    [string]
    $S3Path,

    # Development mode. Lowers intervals to give quicker feedback and retains local output file.
    [switch]
    $DevelopmentMode

)

Begin {

    # Load include file
    If ($PSScriptRoot) {
        $ScriptRoot = $PSScriptRoot
    }
    Else {
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
    $QueryChunkSeconds = $QueryChunkDays * 24 * 60 * 60

    # Local execution?
    If ($DevelopmentMode) {
        $IntervalWaitMinutes = 1 / 6
        $QueryIntervalHours = 1 / 60
    }

    # Set AWS profile and region
    Set-DefaultAWSRegion -Region $AwsRegion
    If (($env:AWS_ROLE_ARN) -and ($env:AWS_WEB_IDENTITY_TOKEN_FILE)) {
        # Authenticate via IAM Roles for Service Accounts (IRSA)
        $UseWebIdentity = $true
        Refresh-AWSWebCreds
    }
    elseif ($AwsProfile) {
        # ... or use the specified AWS profile
        Set-AWSCredential -ProfileName $AwsProfile
    } # ... or use normal credentials search order

    # Test if S3 bucket exists
    If (!(Test-S3Bucket -BucketName $S3BucketName)) {
        throw "S3 bucket ""$S3BucketName"" not found."
    }

    # Test write permission to S3 bucket
    $S3AccessTestKey = "$S3Path/cloudwatchlogs-collector_access_test"
    try { Write-S3Object -BucketName $S3BucketName -Key $S3AccessTestKey -Content 'Test that CloudWatchLogs-Collector can access S3 bucket' }
    catch { throw "Cannot write S3 object ""s3://$S3BucketName/$S3AccessTestKey"": $_" }

    # Test read permission to S3 bucket
    $TempFilePath = New-TemporaryFile | Select-Object -ExpandProperty FullName
    try { Read-S3Object -BucketName $S3BucketName -Key $S3AccessTestKey -File $TempFilePath | Out-Null }
    catch { throw "Cannot read S3 object ""s3://$S3BucketName/$S3AccessTestKey"": $_" }
    Remove-Item $TempFilePath -Force

    # Test delete permission to S3 bucket (access test file only)
    try { Remove-S3Object -BucketName $S3BucketName -Key $S3AccessTestKey -Force }
    catch { throw "Cannot delete S3 object ""s3://$S3BucketName/$S3AccessTestKey"": $_" }

}

Process {

    While ($true) {

        # Refresh AWS credentials from web identity token (if used)
        If ($UseWebIdentity) {
            Refresh-AWSWebCreds
        }

        # Get basic info on log group
        $LogGroup = Get-CWLLogGroup -LogGroupNamePrefix $LogGroupName | Where-Object { $_.LogGroupName -eq $LogGroupName }
        if (!($LogGroup)) {
            throw "CloudWatch log group ""$LogGroupName"" not found."
        }
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
                EndTime   = $EndTime
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
            If (!($DevelopmentMode)) {
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