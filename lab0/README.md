# Лаба 0 - свой сервис (общий TODO List, без удаления))) )

- **Фронтенд** — Vite + vanilla JS. [`frontend/`](frontend/)
- **Бэкенд** — Go + Gin + GORM. [`backend/`](backend/)
- **База данных** — PostgreSQL

![Скриншот работающего приложения](frontend/docs/screenshot.png)

### Запуск


## Что нужно установить

- **Go** 1.25+
- **PostgreSQL** 14+
- **Node.js** 18+

1) Database - Устанавливается локально

```
  psql postgres
  CREATE USER todo_list_user WITH PASSWORD '12345678';
  CREATE DATABASE todo_list_db WITH OWNER = todo_list_user;
```
2) Backend
```
  cd lab0/backend
  cp .env.example .env

  # .env:
  #    PORT=5040
  #    DB_HOST=localhost
  #    DB_USER=todo_list_user
  #    DB_PASSWORD=12345678
  #    DB_NAME=todo_list_db
  #    DB_PORT=5432

  go run ./internal
```

3) Фронтенд:
```
  cd lab0/frontend
  npm install
  cp .env.example .env

  # .env:
  #   VITE_BACKEND_URL=/api
  #   BACKEND_PROXY_TARGET=http://localhost:5040        # локальный бэкенд
  #   # или туннель:
  #   BACKEND_PROXY_TARGET=https://<subdomain>.tunnel4.com

  npm run dev
```

```
lab0/
├── backend/
│   ├── internal/         # main, handler, dto, entities, database, logger
│   ├── migrations/       # SQL-миграции (up/down), golang-migrate
│   ├── go.mod / go.sum
│   └── .env.example
└── frontend/
    ├── src/              # main.js, api.js (контракты + mock), style.css
    ├── index.html
    ├── vite.config.js    # dev/preview + прокси /api → бэкенд (нативный forward)
    ├── docs/screenshot.png
    └── .env.example
```
