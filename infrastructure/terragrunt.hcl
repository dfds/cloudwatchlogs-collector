# Terragrunt will copy the Terraform configurations specified by the source parameter, along with any files in the
# working directory, into a temporary folder, and execute your Terraform commands in that folder.

# Configure Terragrunt to automatically store tfstate files in an S3 bucket
remote_state {
  backend = "s3"
  config = {
    encrypt        = true
    bucket         = "dfds-oxygen-ded-terraform-state"
    key            = "cloudwatchlogs-collector/${path_relative_to_include()}/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "ded-terraform-locks"
  }
}

terraform {
  source = "${get_terragrunt_dir()}"
}

inputs = {
  s3_bucket = "dfds-datalake"
}