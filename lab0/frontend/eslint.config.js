import js from '@eslint/js'
import globals from 'globals'

export default [
  {
    ignores: ['dist/**', 'node_modules/**', 'coverage/**'],
  },
  {
    files: ['src/**/*.js', '*.js'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
    rules: {
      ...js.configs.recommended.rules,
      'no-unused-vars': 'error',
      'no-undef': 'error',
    },
  },
]
