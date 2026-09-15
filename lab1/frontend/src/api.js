// API-слой. Контракты:
//   POST /task   body: { task: { title: string } }
//   GET  /tasks  response: { tasks: Task[] }   Task = { title: string }
//
// Если VITE_BACKEND_URL пуст — работаем на mock-данных в памяти.
// Никаких cookies/localStorage: данные живут только до перезагрузки страницы.

const BACKEND_URL = (import.meta.env.VITE_BACKEND_URL || '').trim()

export const isMock = BACKEND_URL === ''

// ---- Mock-хранилище (в памяти) --------------------------------------------

const mockTasks = [
  { title: 'Поднять фронт локально' },
  { title: 'Прикрутить бэкенд через .env' },
]

async function mockGetTasks() {
  // копия, чтобы наружу не утекла ссылка на внутренний массив
  return mockTasks.map((t) => ({ ...t }))
}

async function mockCreateTask(task) {
  mockTasks.push({ title: task.title })
  return { title: task.title }
}

// ---- Реальный бэкенд -------------------------------------------------------

function url(path) {
  return `${BACKEND_URL.replace(/\/$/, '')}${path}`
}

async function httpGetTasks() {
  const res = await fetch(url('/tasks'), {
    method: 'GET',
    headers: { Accept: 'application/json' },
  })
  if (!res.ok) throw new Error(`GET /tasks → ${res.status}`)
  const body = await res.json()
  return Array.isArray(body.tasks) ? body.tasks : []
}

async function httpCreateTask(task) {
  const res = await fetch(url('/task'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ task: { title: task.title } }),
  })
  if (!res.ok) throw new Error(`POST /task → ${res.status}`)
  return task
}

// ---- Публичный интерфейс ---------------------------------------------------

export function getTasks() {
  return isMock ? mockGetTasks() : httpGetTasks()
}

export function createTask(title) {
  const task = { title: String(title).trim() }
  return isMock ? mockCreateTask(task) : httpCreateTask(task)
}
