variable "aws_region" {
  description = "AWS region for all resources (must support S3 Vectors and the Bedrock models)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "rag-poc"
}

variable "embed_model_id" {
  description = "Bedrock embedding model (index dimension must match its output)."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "embed_dimensions" {
  description = "Vector index dimension. 1024 for Titan Text Embeddings V2 (cannot change after creation)."
  type        = number
  default     = 1024
}

variable "llm_model_id" {
  description = "Bedrock LLM used to generate the final answer from retrieved context."
  type        = string
  default     = "amazon.nova-lite-v1:0"
}

variable "chunk_size" {
  description = "Target chunk size in characters."
  type        = number
  default     = 1000
}

variable "chunk_overlap" {
  description = "Character overlap between consecutive chunks."
  type        = number
  default     = 200
}

variable "top_k" {
  description = "Chunks retrieved per question."
  type        = number
  default     = 5
}
