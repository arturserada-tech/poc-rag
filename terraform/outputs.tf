output "site_url" {
  description = "Static site (S3 website endpoint, HTTP)."
  value       = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}

output "query_url" {
  description = "Query Lambda Function URL. POST {\"question\": \"...\"} to it."
  value       = aws_lambda_function_url.query.function_url
}

output "docs_bucket" {
  description = "Drop .pdf files here to trigger ingestion."
  value       = aws_s3_bucket.docs.id
}

output "vector_bucket" {
  description = "S3 Vectors vector bucket name."
  value       = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
}

output "index_name" {
  description = "S3 Vectors index name."
  value       = aws_s3vectors_index.docs.index_name
}
