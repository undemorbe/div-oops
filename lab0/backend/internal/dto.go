package main

type PostTaskRequest struct {
	Task TaskModel `json:"task"`
}

type GetPortResponse struct {
	Port string `json:"port"`
}

type GetTasksResponse struct {
	Tasks []TaskModel `json:"tasks"`
}

type TaskModel struct {
	Title string `json:"title"`
}
