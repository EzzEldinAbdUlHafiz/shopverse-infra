terraform {
  backend "s3" {
    bucket       = "shopverse-tfstate-676206911950"
    key          = "main/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}