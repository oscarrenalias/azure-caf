FROM mcr.microsoft.com/azurelinux/base/python:3.13
WORKDIR /app
COPY . user_agent/
WORKDIR /app/user_agent
RUN pip install --upgrade --ignore-installed pip && \
    pip install -r requirements.txt
EXPOSE 8088
RUN PYTHONDONTWRITEBYTECODE= python3 -m compileall -q . || true
CMD ["python3", "main.py"]
