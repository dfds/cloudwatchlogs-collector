Function Refresh-AWSWebCreds {
    Write-Host "Refreshing AWS credentials from token at ""$env:AWS_WEB_IDENTITY_TOKEN_FILE""."
    $AWS_CREDS = Use-STSWebIdentityRole -RoleArn $env:AWS_ROLE_ARN -RoleSessionName $env:HOSTNAME -WebIdentityToken $(Get-Content $env:AWS_WEB_IDENTITY_TOKEN_FILE) -Select 'Credentials' -Duration 3600
    Set-AWSCredential -Credential $AWS_CREDS -Scope Global
}

Function Get-DateTime {

    [CmdletBinding(DefaultParameterSetName = 'DateTime')]

    param (
        [Parameter(ParameterSetName = 'DateTime')]
        [datetime]
        $Date,

        [Parameter(ParameterSetName = 'UnixTime', Mandatory)]
        [int64]
        $UnixTime
    )

    # Get specified time or current
    Switch ($PSCmdlet.ParameterSetName) {
        "DateTime" {
            if ($Date) {
                $DateTime = Get-Date -Date $Date
            }
            else {
                $DateTime = Get-Date
            }
        }
        "UnixTime" {
            $InputUnixTime = $UnixTime
            $DateTime = ([datetimeoffset]::FromUnixTimeSeconds($UnixTime)).LocalDateTime
        }
    }

    # Convert time
    $Epoch = ([datetimeoffset]::FromUnixTimeSeconds(0)).DateTime
    $DateTimeUTC = (Get-Date -Date $DateTime).ToUniversalTime()
    $UnixTimeS = [math]::Round((($DateTimeUTC - $Epoch) | Select-Object -Expand TotalSeconds), 3)

    # Return date in various formats
    Return [pscustomobject]@{
        Epoch          = $Epoch
        InputDateTime  = $Date
        InputUnixTime  = $InputUnixTime
        DateTime       = $DateTime
        DateTimeUTC    = $DateTimeUTC
        ISOSortable    = (Get-Date $DateTime -Format u) -replace "Z$", ""
        ISOSortableUTC = (Get-Date $DateTimeUTC -Format u) -replace "Z$", ""
        TimeStamp      = Get-Date -Date $DateTime -Format "yyyyMMdd-HHmmss"
        TimeStampUTC   = Get-Date -Date $DateTimeUTC -Format "yyyyMMdd-HHmmss"
        UnixTime       = [int64]$UnixTimeS
        UnixTimeMs     = [int64]$UnixTimeS * 1000
    }

}