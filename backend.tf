terraform {
  backend "s3" {
    bucket       = "shopverse-tfstate-placeholder"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
