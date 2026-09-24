package main

import (
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type Task struct {
	ID    uuid.UUID `gorm:"type:uuid;primaryKey"`
	Title string    `gorm:"not null"`
}

func (t *Task) BeforeCreate(db *gorm.DB) error {
	if t.ID == uuid.Nil {
		t.ID = uuid.New()
	}
	return nil
}
