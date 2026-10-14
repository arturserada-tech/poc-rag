# Serverless RAG PoC on AWS

A fully serverless Retrieval-Augmented Generation (RAG) solution on AWS. Ask questions through a web UI and get answers grounded in those documents, with citations back to the source PDF and page.

## Prerequisites

| Requirement | Notes |
|---|---|
| Terraform >= 1.5.0 | `terraform -version` |
| AWS credentials | Admin-ish rights for S3, Lambda, IAM, S3 Vectors, Bedrock (`aws configure`) |
| Bedrock model access | Enabled **Amazon Titan Embed Text V2** and **Amazon Nova Lite** in the target region |
| Python 3 + pip | Used locally by Terraform to build the ingest Lambda package |
| Region | Must support S3 Vectors (default: `us-east-1`) |

## Deploy

From the `terraform/` directory:

```powershell
terraform init
terraform apply
```

Terraform will:

1. Build the ingest Lambda package locally (installs `pypdf`, zips it).
2. Create the private documents bucket, the public static-site bucket, and the
   S3 Vectors bucket + `documents` index (1024 dimensions, cosine).
3. Create IAM roles and the two Lambda functions (`*-ingest`, `*-query`).
4. Wire the S3 → Lambda event notification for `.pdf` objects.
5. Upload the web UI with the query API URL baked in, and seed the document
   bucket with the sample PDF shipped in `static/`.

Optional variable overrides:

```powershell
terraform apply -var "aws_region=eu-west-1" -var "project=my-rag"
```

## After deployment

`terraform apply` prints the outputs:

| Output | Meaning |
|---|---|
| `site_url` | Web UI (S3 website endpoint, HTTP) |
| `query_url` | Query Lambda Function URL — POST `{"question": "..."}` |
| `docs_bucket` | Upload `.pdf` files here to trigger ingestion |
| `vector_bucket` / `index_name` | S3 Vectors bucket and index |

## Configuration variables

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | Region for all resources |
| `project` | `rag-poc` | Name prefix for all resources |
| `embed_model_id` | `amazon.titan-embed-text-v2:0` | Embedding model |
| `embed_dimensions` | `1024` | Index dimension (cannot change after creation) |
| `llm_model_id` | `amazon.nova-lite-v1:0` | Answer-generation model |
| `chunk_size` / `chunk_overlap` | `1000` / `200` | Chunking in characters |
| `top_k` | `5` | Chunks retrieved per question |

## Tear down

```powershell
terraform destroy
```
