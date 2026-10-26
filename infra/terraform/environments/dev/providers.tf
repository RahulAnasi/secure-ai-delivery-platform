provider "aws" {
  region              = "ap-south-1"
  profile             = "secure-ai-terraform"
  allowed_account_ids = ["884596874125"]

  default_tags {
    tags = {
      Project     = "secure-ai-delivery-platform"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }
}