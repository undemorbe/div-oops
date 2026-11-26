import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

beforeEach(() => {
  vi.resetModules()
  vi.stubEnv('VITE_BACKEND_URL', '')
})

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('task API in mock mode', () => {
  it('uses mock mode when backend URL is empty', async () => {
    const { isMock } = await import('./api.js')

    expect(isMock).toBe(true)
  })

  it('returns the initial tasks', async () => {
    const { getTasks } = await import('./api.js')
    const tasks = await getTasks()

    expect(tasks.length).toBeGreaterThanOrEqual(2)
    expect(tasks.some((task) => task.title === 'Поднять фронт локально')).toBe(true)
  })

  it('trims and stores a new task', async () => {
    const { createTask, getTasks } = await import('./api.js')
    const title = `CI test ${Date.now()}`

    const created = await createTask(`  ${title}  `)
    const tasks = await getTasks()

    expect(created.title).toBe(title)
    expect(tasks.some((task) => task.title === title)).toBe(true)
  })
})
