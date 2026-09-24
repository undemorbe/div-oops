package main

import (
	"os"

	log "github.com/sirupsen/logrus"
)

var Log *log.Logger

func InitLogger() {
	Log = log.New()

	Log.SetOutput(os.Stdout)

	Log.SetFormatter(&log.TextFormatter{FullTimestamp: true})
	Log.SetLevel(log.InfoLevel)
}
