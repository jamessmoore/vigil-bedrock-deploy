output "state_bucket_name" {
  description = "Pass to the main stack's `terraform init -backend-config=bucket=...`."
  value       = aws_s3_bucket.state.id
}

output "deployer_user_arn" {
  value = aws_iam_user.deployer.arn
}

output "deployer_access_key_id" {
  description = "Access key id for the deployer user (null if create_access_key=false)."
  value       = try(aws_iam_access_key.deployer[0].id, null)
}

output "deployer_secret_access_key" {
  description = "Secret access key — sensitive. Store in a credentials manager; it also lives in this bootstrap's local state."
  value       = try(aws_iam_access_key.deployer[0].secret, null)
  sensitive   = true
}
