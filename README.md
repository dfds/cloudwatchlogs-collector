# cloudwatchlogs-collector
Script and Docker manifest for collecting CloudWatch Logs and storing them in S3

## Deployment flow
### Collector deployment
1) Change code in ./eks/ folder
2) Create release in Github
3) Release tag triggers build in [Docker Hub](https://hub.docker.com/repository/docker/dfdsdk/cloudwatchlogs-collector/tags?page=1)
4) Update image tag in deployment manifests in ./k8s/ folder
5) This triggers CI/CD in ADO

### Infrastructure deployment
1) Code changes in ./infrastructure/ folder
2) This triggers CI/CD in ADO
