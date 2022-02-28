variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "s3_bucket" {
  type = string
}

variable "oidc_account_id" {
  type        = string
  description = "The AWS account ID in which the OpenID Connector for the EKS cluster resides."
}

variable "oidc_provider" {
  type        = string
  description = "Like \"oidc.eks.$REGION.amazonaws.com/id/$ID\""
}

variable "k8s_namespace" {
  type        = string
  default     = "logcollect"
  description = "The Kubernetes namespace CloudWatchLogs-Collector is deployed in."
}

variable "k8s_serviceaccount" {
  type        = string
  default     = "cloudwatchlogs-collector-sa"
  description = "The Kubernetes Service Account used by CloudWatchLogs-Collector."
}
