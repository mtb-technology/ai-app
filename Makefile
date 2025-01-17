# Makefile for setting up and running Danswer

# Variables
PYTHON_VERSION=3.11
VENV_DIR=../.venv
DOCKER_COMPOSE_FILE=deployment/docker_compose/docker-compose.dev.yml
DOCKER_COMPOSE_PROJECT=danswer-stack
BACKEND_DIR=backend
FRONTEND_DIR=web
ACTIVATE_VENV=./activate_venv.sh
PORTS=9000 8080

# Determine the correct docker-compose command
COMPOSE_CMD=$(shell command -v docker-compose > /dev/null 2>&1 && echo "docker-compose" || echo "docker compose")

# Load environment variables from the specific .env file
include deployment/docker_compose/.env
export $(shell sed 's/=.*//' deployment/docker_compose/.env)

# Commands
.PHONY: help setup_venv install_backend install_frontend install_playwright start_docker start_frontend start_model_server migrate_db start_background_jobs start_backend lint_backend format_frontend start pull_latest_docker

help:
	@echo "Danswer Makefile"
	@echo "Usage:"
	@echo "  make setup_venv          Create a Python virtual environment"
	@echo "  make install_backend     Install backend dependencies"
	@echo "  make install_frontend    Install frontend dependencies"
	@echo "  make install_playwright  Install Playwright"
	@echo "  make start_docker        Start Docker containers for Vespa and Postgres"
	@echo "  make start_frontend      Start the frontend server"
	@echo "  make start_model_server  Start the model server"
	@echo "  make migrate_db          Run database migrations"
	@echo "  make start_background_jobs Start background jobs"
	@echo "  make start_backend       Start the backend API server"
	@echo "  make lint_backend        Run linting checks on the backend code"
	@echo "  make format_frontend     Run formatter on the frontend code"
	@echo "  make start               Start Docker containers, model server, background jobs, and backend API server"
	@echo "  make pull_latest_docker  Pull the latest changes from Docker Hub"

setup_venv:
	python -m venv $(VENV_DIR)
	@echo "Virtual environment created. To activate it, run:"
	@echo "$(ACTIVATE_VENV)"

install_backend: setup_venv
	$(ACTIVATE_VENV) pip install -r $(BACKEND_DIR)/requirements/default.txt && \
	$(ACTIVATE_VENV) pip install -r $(BACKEND_DIR)/requirements/dev.txt && \
	$(ACTIVATE_VENV) pip install -r $(BACKEND_DIR)/requirements/model_server.txt
	$(ACTIVATE_VENV) pip install -r $(BACKEND_DIR)/requirements/ee.txt

install_frontend:
	cd $(FRONTEND_DIR) && npm install

install_playwright:
	$(ACTIVATE_VENV) playwright install

start_docker:
	$(COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE) -p $(DOCKER_COMPOSE_PROJECT) up -d index relational_db

start_frontend:
	cd $(FRONTEND_DIR) && npm run dev

start_model_server:
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && uvicorn model_server.main:app --reload --port 9000

migrate_db:
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && alembic upgrade head

reset_db:
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && alembic downgrade base

start_background_jobs:
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && python ./scripts/dev_run_background_jobs.py

start_backend:
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) &&  uvicorn danswer.main:app --reload --port 8080

lint_backend:
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && pre-commit install && $(ACTIVATE_VENV) python -m mypy .

format_frontend:
	cd $(FRONTEND_DIR) && npx prettier --write .

start: start_docker
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && uvicorn model_server.main:app --reload --port 9000 & \
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && python ./scripts/dev_run_background_jobs.py & \
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && AUTH_TYPE=disabled uvicorn danswer.main:app --reload --port 8080 & \
	wait
	@echo "All services started successfully."

start-dev: start_docker
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && uvicorn model_server.main:app --reload --port 9000 & \
	$(ACTIVATE_VENV) && cd $(BACKEND_DIR) && python ./scripts/dev_run_background_jobs.py & \
	wait
	@echo "All services started successfully."

stop:
	$(COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE) -p $(DOCKER_COMPOSE_PROJECT) down
	@echo "Stopping all running processes..."
	-@pkill -f "uvicorn model_server.main:app --reload --port 9000"
	-@pkill -f "python ./scripts/dev_run_background_jobs.py"
	-@pkill -f "uvicorn danswer.main:app --reload --port 8080"
	-@pkill -f "celery -A danswer.background.celery worker --pool=threads --autoscale=3,10 --loglevel=INFO --concurrency=1"
	-@pkill -f "celery -A danswer.background.celery beat --loglevel=INFO"
	@echo "All services stopped."

kill-ports:
	@for PORT in $(PORTS); do \
		echo "Killing process on port $$PORT..."; \
		PID=$$(lsof -t -i:$$PORT); \
		if [ -n "$$PID" ]; then \
			kill -9 $$PID; \
			echo "Killed process $$PID on port $$PORT"; \
		else \
			echo "No process found on port $$PORT"; \
		fi \
	done

restore-db-from-bk:
	$(COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE) -p $(DOCKER_COMPOSE_PROJECT) exec relational_db psql -U $(POSTGRES_USER) -c "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '$(POSTGRES_DB)' AND pid <> pg_backend_pid();"
	$(COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE) -p $(DOCKER_COMPOSE_PROJECT) exec relational_db dropdb $(POSTGRES_DB) -U $(POSTGRES_USER) && sleep 5
	$(COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE) -p $(DOCKER_COMPOSE_PROJECT) exec relational_db createdb $(POSTGRES_DB) -U $(POSTGRES_USER) && sleep 5
	PGPASSWORD=$(POSTGRES_PASSWORD) pg_restore --no-privileges --no-owner --username $(POSTGRES_USER) --host=127.0.0.1 --port=5432 --dbname $(POSTGRES_DB) --verbose bk/chatemployee.api.bk

clone-prod-db:
	TODAY=$(shell date +%d-%m-%Y) && \
	rm -rf bk/jdm-$${TODAY}.api.bk && \
	mkdir -p bk && \
	ssh -i /Users/beaudinngreve/.ssh/id_rsa root@161.35.151.159 'export PGPASSWORD="password@jdm-db-user123" && pg_dump --no-privileges --no-owner --username="jdm-db-user" --host="localhost" --port="5432" --file="/var/tmp/jdm-prod-db" --format="d" --clean --verbose' && \
	scp -r -i /Users/beaudinngreve/.ssh/id_rsa root@161.35.151.159:/var/tmp/jdm-prod-db bk/jdm-$${TODAY}.api.bk && \
	ssh -i /Users/beaudinngreve/.ssh/id_rsa root@161.35.151.159 'rm -rf /var/tmp/jdm-prod-db'
	make restore-db-from-bk


clone-locale-db:
	rm -rf bk/jdm.bk
	mkdir -p bk
	PGPASSWORD=$(POSTGRES_PASSWORD) pg_dump --no-privileges --no-owner --username=$(POSTGRES_USER) --host=127.0.0.1 --port=5432 --file="bk/jdm.bk" --dbname=$(POSTGRES_DB) --format="d" --clean --verbose --exclude-table-data='chat_session' --exclude-table-data='chat_message__search_doc' --exclude-table-data='chat_message' --exclude-table-data='chat_feedback' --exclude-table-data='celery_taskmeta' --exclude-table-data='document_retrieval_feedback'

prod-add-db:
	PGPASSWORD="o8gPN05jrfDJUpC" psql --username chatemployee --host=34.32.226.143 --port=5432 --dbname postgres --command "CREATE DATABASE chatemployee_prod;"
	PGPASSWORD="o8gPN05jrfDJUpC" pg_restore --no-privileges --no-owner --username chatemployee --host=34.32.226.143 --port=5432 --dbname chatemployee_prod --verbose bk/chatemployee.api.bk

replace-prod-db:
	# Step 2: Restore local database to the remote server
	PGPASSWORD="password@jdm-db-user123" pg_restore --no-privileges --no-owner --username="jdm-db-user" --host="161.35.151.159" --port="5432" --dbname="postgres" --verbose "bk/jdm.bk"


pull_latest_docker:
	$(COMPOSE_CMD) -f $(DOCKER_COMPOSE_FILE) -p $(DOCKER_COMPOSE_PROJECT) pull
	@echo "Latest Docker images pulled successfully."