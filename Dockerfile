FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_PROGRESS_BAR=off \
    PIP_ROOT_USER_ACTION=ignore \
    GRAPHRAG_ROOT=/app/project

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

# Generate the default prompts from the installed graphrag version, so the prompt
# files always match the library. Any prompts you commit under project/prompts/
# overwrite these in the COPY below. --model/--embedding stop init from prompting
# interactively; only the prompts are kept, so their values don't matter.
RUN graphrag init --root /tmp/init --model gpt-4.1-mini --embedding text-embedding-3-small \
 && mkdir -p project \
 && cp -r /tmp/init/prompts project/prompts \
 && rm -rf /tmp/init

COPY project project
COPY app app
COPY scripts scripts

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
