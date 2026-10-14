import io
import json
import os
import urllib.parse

import boto3
from pypdf import PdfReader

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")
s3vectors = boto3.client("s3vectors")

VECTOR_BUCKET = os.environ["VECTOR_BUCKET"]
INDEX_NAME = os.environ["INDEX_NAME"]
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", "1000"))
CHUNK_OVERLAP = int(os.environ.get("CHUNK_OVERLAP", "200"))
PUT_BATCH_SIZE = 100


def embed_text(text):
    response = bedrock.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps({"inputText": text}),
    )
    return [float(value) for value in json.loads(response["body"].read())["embedding"]]


def extract_page_texts(pdf_bytes):
    reader = PdfReader(io.BytesIO(pdf_bytes))
    return [page.extract_text() or "" for page in reader.pages]


def split_long(paragraph, size):
    pieces, current = [], ""
    for word in paragraph.split(" "):
        while len(word) > size:
            if current:
                pieces.append(current)
                current = ""
            pieces.append(word[:size])
            word = word[size:]
        candidate = f"{current} {word}" if current else word
        if len(candidate) <= size:
            current = candidate
        else:
            if current:
                pieces.append(current)
            current = word
    if current:
        pieces.append(current)
    return pieces


def chunk_pages(page_texts, size=CHUNK_SIZE, overlap=CHUNK_OVERLAP):
    paragraphs = []
    for page_number, page_text in enumerate(page_texts, start=1):
        for paragraph in page_text.split("\n\n"):
            paragraph = " ".join(paragraph.split())
            if paragraph:
                for piece in split_long(paragraph, size):
                    paragraphs.append((piece, page_number))

    chunks = []
    current, current_page = "", None
    for paragraph, page_number in paragraphs:
        if not current:
            current, current_page = paragraph, page_number
            continue
        if len(current) + 1 + len(paragraph) <= size:
            current = f"{current} {paragraph}"
            continue
        chunks.append((current, current_page))
        tail = current[-overlap:] if overlap > 0 else ""
        current = f"{tail} {paragraph}" if tail else paragraph
        current_page = page_number
    if current:
        chunks.append((current, current_page))
    return chunks


def ingest_object(bucket, key):
    pdf_bytes = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    chunks = chunk_pages(extract_page_texts(pdf_bytes))

    vectors = [
        {
            "key": f"{key}#{index}",
            "data": {"float32": embed_text(text)},
            "metadata": {
                "source_key": key,
                "page": page,
                "chunk_index": index,
                "source_text": text,
            },
        }
        for index, (text, page) in enumerate(chunks)
    ]
    for start in range(0, len(vectors), PUT_BATCH_SIZE):
        s3vectors.put_vectors(
            vectorBucketName=VECTOR_BUCKET,
            indexName=INDEX_NAME,
            vectors=vectors[start:start + PUT_BATCH_SIZE],
        )
    return len(vectors)


def handler(event, context):
    for record in event.get("Records", []):
        key = urllib.parse.unquote(record["s3"]["object"]["key"])
        if not key.lower().endswith(".pdf"):
            continue
        if record["eventName"].startswith("ObjectCreated"):
            ingest_object(record["s3"]["bucket"]["name"], key)
    return {"statusCode": 200, "body": "ok"}
