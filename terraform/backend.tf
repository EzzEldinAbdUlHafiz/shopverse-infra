terraform {
  backend "s3" {
    bucket       = "shopverse-tfstate"
    key          = "main/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
