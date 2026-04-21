output "bucket_arn" {
  description = "ARN of the central flow logs S3 bucket"
  value       = aws_s3_bucket.flow_logs.arn
}

output "bucket_name" {
  description = "Name of the central flow logs S3 bucket"
  value       = aws_s3_bucket.flow_logs.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt flow logs"
  value       = aws_kms_key.flow_logs.arn
}

output "kms_key_id" {
  description = "ID of the KMS key used to encrypt flow logs"
  value       = aws_kms_key.flow_logs.key_id
}
