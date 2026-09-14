import './style.css'
import { getTasks, createTask, isMock } from './api.js'

const form = document.getElementById('task-form')
const input = document.getElementById('task-input')
const submitBtn = document.getElementById('task-submit')
const list = document.getElementById('task-list')
const statusEl = document.getElementById('status')
const modeBadge = document.getElementById('mode-badge')

modeBadge.textContent = isMock ? 'mock' : 'backend'
modeBadge.classList.add(isMock ? 'badge--mock' : 'badge--live')

function setStatus(msg, kind = '') {
  statusEl.textContent = msg
  statusEl.className = 'status' + (kind ? ` status--${kind}` : '')
}

function render(tasks) {
  list.innerHTML = ''
  if (tasks.length === 0) {
    const empty = document.createElement('li')
    empty.className = 'list__empty'
    empty.textContent = 'Пока пусто. Добавь первую задачу.'
    list.appendChild(empty)
    return
  }
  for (const task of tasks) {
    const li = document.createElement('li')
    li.className = 'card'
    const title = document.createElement('span')
    title.className = 'card__title'
    title.textContent = task.title
    li.appendChild(title)
    list.appendChild(li)
  }
}

async function loadTasks() {
  setStatus('Загружаю…')
  try {
    const tasks = await getTasks()
    render(tasks)
    setStatus('')
  } catch (err) {
    setStatus(`Не удалось загрузить: ${err.message}`, 'error')
  }
}

form.addEventListener('submit', async (e) => {
  e.preventDefault()
  const title = input.value.trim()
  if (!title) return

  submitBtn.disabled = true
  setStatus('Сохраняю…')
  try {
    await createTask(title)
    input.value = ''
    await loadTasks()
  } catch (err) {
    setStatus(`Не удалось сохранить: ${err.message}`, 'error')
  } finally {
    submitBtn.disabled = false
    input.focus()
  }
})

loadTasks()
