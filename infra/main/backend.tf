# Partial configuration. Scripts and CI pass:
#   -backend-config="bucket=<project>-tfstate-<account_id>"
#   -backend-config="key=main/terraform.tfstate"
#   -backend-config="region=<region>"
#   -backend-config="use_lockfile=true"   # S3-native lock; DynamoDB locking is deprecated
terraform {
  backend "s3" {}
}
