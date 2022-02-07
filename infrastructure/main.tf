terraform {
  backend "s3" {}
}

provider "aws" {
  region  = "eu-west-1"
  version = "~>2.43"
}

module "s3_bucket" {
  source    = "git::https://github.com/dfds/infrastructure-modules.git//_sub/storage/s3-bucket?ref=0.2.28"
  s3_bucket = var.s3_bucket
}

resource "aws_glue_catalog_database" "datalake" {
  name = "datalake"
}

resource "aws_glue_catalog_table" "eks-audit" {
  name          = "aws-eks-audit-log"
  database_name = aws_glue_catalog_database.datalake.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "json"
  }

  storage_descriptor {
    location      = "s3://${module.s3_bucket.bucket_name}/aws/eks/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "eks-audit"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "paths" = "objectNamespace,objectResource,timestamp,verb,objectName"
      }
    }

    columns {
      name = "timestamp"
      type = "timestamp"
    }

    columns {
      name = "verb"
      type = "string"
    }

    columns {
      name = "objectresource"
      type = "string"
    }

    columns {
      name = "objectnamespace"
      type = "string"
    }

    columns {
      name = "objectname"
      type = "string"
    }
  }
}

module "iam_role" {
  source               = "git::https://github.com/dfds/infrastructure-modules.git//_sub/security/iam-role?ref=0.2.28"
  role_name            = "CloudWatchLogsCollector"
  role_description     = "Role for CloudWatch Logs Collector, that queries CWL and saves results to S3."
  assume_role_policy   = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::738063116313:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {}
    }
  ]
}
EOF
  role_policy_name     = "CloudWatchLogsCollector"
  role_policy_document = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadCWLGroups",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:StartQuery",
        "logs:GetLogGroupFields"
      ],
      "Resource": "*"
    },
    {
      "Sid": "QueryCWL",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeQueries",
        "logs:GetQueryResults",
        "logs:StopQuery"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WriteDatalakeS3",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${module.s3_bucket.bucket_name}/*",
        "arn:aws:s3:::${module.s3_bucket.bucket_name}"
      ]
    },
    {
      "Sid": "WriteDatalakeS3",
      "Effect": "Allow",
      "Action": [
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${module.s3_bucket.bucket_name}/*/cloudwatchlogs-collector_access_test"
      ]
    }
  ]
}
EOF
}
