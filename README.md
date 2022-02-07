<!-- omit in toc -->
# CloudWatch Logs Collector

[![Contributors][contributors-shield]][contributors-url]
[![Issues][issues-shield]][issues-url]
[![MIT License][license-shield]][license-url]
[![Build Status](https://dev.azure.com/dfds/YourAzureDevOpsProject/_apis/build/status/Name-Of-CI-Pipeline?branchName=master)](https://dev.azure.com/dfds/YourAzureDevOpsProject/_build/latest?definitionId=1378&branchName=master)

<!-- TABLE OF CONTENTS -->
<!-- omit in toc -->
## Table of Contents

- [About The Project](#about-the-project)
  - [Structure](#structure)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
- [Deployment prerequisites](#deployment-prerequisites)
- [Usage](#usage)
- [Deployment Flow](#deployment-flow)
  - [Infrastructure Deployment](#infrastructure-deployment)
  - [Collector Deployment](#collector-deployment)
- [Development](#development)
- [Additional Resources](#additional-resources)
- [License](#license)

<!-- ABOUT THE PROJECT -->
## About The Project

Continuously running Powershell Core script for collecting CloudWatch Logs and storing them in S3.

Queries for larger timespans than the defined threshold, are broken down into smaller chunks. This is to avoid query timeouts and exceeding the 10000 result cap per query. Query results are filtered, transformed and stored in the specified S3 bucket.

The script will then sleep according to the defined query interval, after which the process is repeated.

Docker and Kubernetes manifest for deployment also included.

### Structure

Notable project directories and files:

| Path                   | Usage                                                                 |
| ---------------------- | --------------------------------------------------------------------- |
| `/.vscode/launch.json` | Launch config for debugging (replace variables to suit environment)   |
| `/eks/Dockerfile`      | Dockerfile used for building images with the `eks-{sourceref}` tag    |
| `/eks/src/`            | PowerShell scripts that make up the collector                         |
| `/infrastructure/`     | Terraform/Terragrunt files for deploying infrastructure               |
| `/k8s/`                | Manifest for deploying image to Kubernetes                            |
| `aws-iam-policy.json`  | Policy granting permissions to the `CloudwatchlogsCollector` IAM role |
| `azure-pipelines.yaml` | Pipeline spec to deploy infrastructure and collector                  |
| `schema.json`          | Structured description of input/output schema used by collector       |

<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

- [Powershell Core][powershell-core] (tested with 7.x)
- [AWS Tools for Powershell NetCore][aws-powershell] 4.0.0+

## Deployment prerequisites

With the change to scoped Kubernetes service connections during deploment, certain manifests have been moved out of the k8s directory and moved to the *k8s_initial* directory.

The manifests within *k8s_initial* will have to be run manually or with a different service connection due to elevated rights.

<!-- USAGE EXAMPLES -->
## Usage

The script usage is documented natively in PowerShell. To get the most up-to-date help, invoke:

```powershell
Get-Help ./eks/src/Query-CloudWatchLogs.ps1 -Detailed
```

The priority is to update the built-in help when relevant. The following table of the script arguments and their description is provided for convenience, but might not always we up-to-date:

| Argument            | Description                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| AwsProfile          | Name of the AWS profile to use for authentication. If not specified, the normal credential search order is used.                     |
| AwsRegion           | AWS region where the CloudWatch Logs and target S3 bucket reside, e.g. 'eu-west-1'.                                                  |
| LogGroupName        | Name of the CloudWatch Logs log group to query. By default, AWS EKS will log to a log group named '/aws/eks/${clustername}/cluster'. |
| LogStreamNamePrefix | Part of the log stream names to be included as a filter in the CloudWatch Logs query, e.g. 'kube-apiserver-audit-'                   |
| QueryIntervalHours  | Interval at which queries will be executed. The script will sleep in-between. (default: 1 week minus one hour)                       |
| QueryRetrySeconds   | How long to sleep, before retrying failed queries. (default: 10)                                                                     |
| QueryChunkDays      | The timespan length to break down queries into. (default: 2 weeks)                                                                   |
| IntervalWaitMinutes | The interval at which to check if query interval has passed. (default: 60)                                                           |
| S3BucketName        | The S3 bucket the output file is uploaded to.                                                                                        |
| S3Path              | The path (or directory) in the S3 bucket to store the output file.                                                                   |
| LocalExec           | Used for local execution/debugging. Lowers intervals to give quicker feedback and retains local output file.                         |

Additional resources, including documentation on CloudWatch Logs query syntax, AWS Tools for PowerShell authentication etc., can be listed by running:

```powershell
Get-Help .\eks\src\Query-CloudWatchLogs.ps1 -Full | Select -Expand relatedLinks
```

See also [Additional Resources](#additional-resources).

## Deployment Flow

### Infrastructure Deployment

1. Code changes in `./infrastructure/` folder
2. This triggers CI/CD in Azure DevOps

### Collector Deployment

1. Change code in `./eks/` folder
2. Create release in Github (`/^[0-9.]+/`)
3. Release tag triggers build in [Docker Hub][docker-tags]
4. Update image tag in deployment manifests in `./k8s/` folder
5. This triggers CI/CD in Azure DevOps

## Development

Run `skaffold dev`.

## Additional Resources

- [AWS Tools for Powershell Docs: Using AWS Credentials][aws-docs-credentials]
- [AWS Tools for Powershell Docs: CloudWatch Logs Insights Query Syntax][aws-docs-cwl-query]

<!-- LICENSE -->
## License

Distributed under the MIT License. See `LICENSE` for more information.

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[contributors-shield]: https://img.shields.io/github/contributors/dfds/cloudwatchlogs-collector?style=plastic
[contributors-url]: https://github.com/dfds/cloudwatchlogs-collector/graphs/contributors
[issues-shield]: https://img.shields.io/github/issues/dfds/cloudwatchlogs-collector?style=plastic
[issues-url]: https://github.com/dfds/cloudwatchlogs-collector/issues
[license-shield]: https://img.shields.io/github/license/dfds/cloudwachlogs-collector?style=plastic
[license-url]: https://github.com/dfds/cloudwatchlogs-collector/blob/master/LICENSE
[powershell-core]: https://github.com/PowerShell/PowerShell/releases
[aws-powershell]: https://docs.aws.amazon.com/powershell/latest/userguide/pstools-getting-set-up.html
[docker-tags]: https://hub.docker.com/r/dfdsdk/cloudwatchlogs-collector/tags
[aws-docs-credentials]: https://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html
[aws-docs-cwl-query]: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html
