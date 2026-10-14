provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  index_name = "documents"
  src_ingest = "${path.module}/../src/ingest"
  src_query  = "${path.module}/../src/query"

  index_html = replace(
    file("${path.module}/../static/index.html"),
    "__API_URL__",
    aws_lambda_function_url.query.function_url
  )
}

resource "aws_s3_bucket" "docs" {
  bucket = "${var.project}-docs-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "site" {
  bucket = "${var.project}-site-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_policy" "site_public_read" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  content      = local.index_html
  content_type = "text/html"
  etag         = md5(local.index_html)
}

resource "aws_s3_object" "seed_pdfs" {
  for_each = fileset("${path.module}/../static", "*.pdf")

  bucket       = aws_s3_bucket.docs.id
  key          = each.value
  source       = "${path.module}/../static/${each.value}"
  content_type = "application/pdf"
  etag         = filemd5("${path.module}/../static/${each.value}")

  depends_on = [aws_s3_bucket_notification.docs]
}

resource "aws_s3vectors_vector_bucket" "vectors" {
  vector_bucket_name = "${var.project}-vec-${local.account_id}"
  force_destroy      = true
}

resource "aws_s3vectors_index" "docs" {
  vector_bucket_name = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
  index_name         = local.index_name
  data_type          = "float32"
  dimension          = var.embed_dimensions
  distance_metric    = "cosine"

  metadata_configuration {
    non_filterable_metadata_keys = ["source_text", "page", "chunk_index"]
  }
}

resource "aws_iam_role" "lambda" {
  for_each = toset(["ingest", "query"])
  name     = "${var.project}-${each.key}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = toset(["ingest", "query"])
  name              = "/aws/lambda/${var.project}-${each.key}"
  retention_in_days = 7
}

resource "null_resource" "package_ingest" {
  triggers = {
    app          = filesha256("${local.src_ingest}/app.py")
    requirements = filesha256("${local.src_ingest}/requirements.txt")
  }

 provisioner "local-exec" {
    interpreter = ["python", "-c"]

    environment = {
      BUILD_DIR  = "${path.module}/.build/ingest"
      SRC_INGEST = local.src_ingest
    }

    command = <<-PY
      import os, shutil, subprocess, sys
      from pathlib import Path

      build_dir = Path(os.environ["BUILD_DIR"]).resolve()
      src_ingest = Path(os.environ["SRC_INGEST"]).resolve()

      if build_dir.exists():
          shutil.rmtree(build_dir)
      build_dir.mkdir(parents=True, exist_ok=True)

      subprocess.check_call([
          sys.executable, "-m", "pip", "install",
          "--disable-pip-version-check",
          "--platform", "manylinux_2_28_x86_64",
          "--target", str(build_dir),
          "--only-binary=:all:",
          "--implementation", "cp",
          "--python-version", "3.13",
          "-r", str(src_ingest / "requirements.txt")
      ])

      shutil.copy(src_ingest / "app.py", build_dir / "app.py")
    PY
  }
}

data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.module}/.build/ingest"
  output_path = "${path.module}/.build/ingest.zip"

  depends_on = [null_resource.package_ingest]
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "ReadSourcePdf"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.docs.arn}/*"]
  }

  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda["ingest"].arn}:*"]
  }

  statement {
    sid = "WriteVectors"
    actions = [
      "s3vectors:PutVectors",
      "s3vectors:DeleteVectors",
      "s3vectors:ListVectors",
      "s3vectors:GetVectors",
    ]
    resources = [
      aws_s3vectors_vector_bucket.vectors.vector_bucket_arn,
      aws_s3vectors_index.docs.index_arn,
    ]
  }

  statement {
    sid       = "Embed"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embed_model_id}"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "${var.project}-ingest"
  role   = aws_iam_role.lambda["ingest"].id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${var.project}-ingest"
  role             = aws_iam_role.lambda["ingest"].arn
  handler          = "app.handler"
  runtime          = "python3.13"
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  environment {
    variables = {
      VECTOR_BUCKET  = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
      INDEX_NAME     = aws_s3vectors_index.docs.index_name
      EMBED_MODEL_ID = var.embed_model_id
      CHUNK_SIZE     = tostring(var.chunk_size)
      CHUNK_OVERLAP  = tostring(var.chunk_overlap)
    }
  }

  depends_on = [
    aws_iam_role_policy.ingest,
    aws_cloudwatch_log_group.lambda["ingest"],
  ]
}

resource "aws_lambda_permission" "s3_invoke_ingest" {
  statement_id   = "AllowExecutionFromS3"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ingest.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.docs.arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "docs" {
  bucket = aws_s3_bucket.docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_suffix       = ".pdf"
  }

  depends_on = [aws_lambda_permission.s3_invoke_ingest]
}

data "archive_file" "query" {
  type        = "zip"
  source_file = "${local.src_query}/app.py"
  output_path = "${path.module}/.build/query.zip"
}

data "aws_iam_policy_document" "query" {
  statement {
    sid = "ReadVectors"
    actions = [
      "s3vectors:QueryVectors",
      "s3vectors:GetVectors",
    ]
    resources = [
      aws_s3vectors_vector_bucket.vectors.vector_bucket_arn,
      aws_s3vectors_index.docs.index_arn,
    ]
  }

  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda["query"].arn}:*"]
  }

  statement {
    sid       = "Inference"
    actions   = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.embed_model_id}",
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.llm_model_id}",
    ]
  }
}

resource "aws_iam_role_policy" "query" {
  name   = "${var.project}-query"
  role   = aws_iam_role.lambda["query"].id
  policy = data.aws_iam_policy_document.query.json
}

resource "aws_lambda_function" "query" {
  function_name    = "${var.project}-query"
  role             = aws_iam_role.lambda["query"].arn
  handler          = "app.handler"
  runtime          = "python3.13"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.query.output_path
  source_code_hash = data.archive_file.query.output_base64sha256

  environment {
    variables = {
      VECTOR_BUCKET  = aws_s3vectors_vector_bucket.vectors.vector_bucket_name
      INDEX_NAME     = aws_s3vectors_index.docs.index_name
      EMBED_MODEL_ID = var.embed_model_id
      LLM_MODEL_ID   = var.llm_model_id
      TOP_K          = tostring(var.top_k)
    }
  }

  depends_on = [
    aws_iam_role_policy.query,
    aws_cloudwatch_log_group.lambda["query"],
  ]
}

resource "aws_lambda_function_url" "query" {
  function_name      = aws_lambda_function.query.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["http://${aws_s3_bucket_website_configuration.site.website_endpoint}"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}