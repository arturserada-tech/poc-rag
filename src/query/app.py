import json
import os

import boto3

bedrock = boto3.client("bedrock-runtime")
s3vectors = boto3.client("s3vectors")

VECTOR_BUCKET = os.environ["VECTOR_BUCKET"]
INDEX_NAME = os.environ["INDEX_NAME"]
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
LLM_MODEL_ID = os.environ.get("LLM_MODEL_ID", "amazon.nova-lite-v1:0")
TOP_K = int(os.environ.get("TOP_K", "5"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "1024"))

PROMPT_TEMPLATE = """You answer questions using ONLY the context below.
If the context does not contain the answer, say that you don't know.
Cite the context chunk numbers you used, like [1] or [2].

Context:
{context}

Question: {question}
Answer:"""


def embed_text(text):
    response = bedrock.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps({"inputText": text}),
    )
    return [float(value) for value in json.loads(response["body"].read())["embedding"]]


def retrieve(question):
    response = s3vectors.query_vectors(
        vectorBucketName=VECTOR_BUCKET,
        indexName=INDEX_NAME,
        queryVector={"float32": embed_text(question)},
        topK=TOP_K,
        returnMetadata=True,
        returnDistance=True,
    )

    sources, contexts = [], []
    for number, hit in enumerate(response.get("vectors", []), start=1):
        metadata = hit.get("metadata") or {}
        text = metadata.get("source_text", "")
        if not text:
            continue
        sources.append(
            {
                "n": number,
                "source": metadata.get("source_key"),
                "page": metadata.get("page"),
                "distance": hit.get("distance"),
                "text": text,
            }
        )
        contexts.append(f"[{number}] {text}")
    return sources, contexts


def call_llm(prompt):
    response = bedrock.invoke_model(
        modelId=LLM_MODEL_ID,
        body=json.dumps(
            {
                "messages": [{"role": "user", "content": [{"text": prompt}]}],
                "inferenceConfig": {"maxTokens": MAX_TOKENS, "temperature": 0},
            }
        ),
    )
    output = json.loads(response["body"].read())
    return output["output"]["message"]["content"][0]["text"]


def respond(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
        },
        "body": json.dumps(payload),
    }


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
        question = (body.get("question") or "").strip()
        if not question:
            return respond(400, {"error": "missing 'question' in JSON body"})

        sources, contexts = retrieve(question)
        if not contexts:
            return respond(
                200,
                {
                    "answer": "No indexed documents found. Upload a PDF to the documents bucket and wait for ingestion.",
                    "sources": [],
                },
            )

        prompt = PROMPT_TEMPLATE.format(question=question, context="\n\n".join(contexts))
        return respond(200, {"answer": call_llm(prompt), "sources": sources})
    except Exception as error:
        return respond(500, {"error": str(error)})
