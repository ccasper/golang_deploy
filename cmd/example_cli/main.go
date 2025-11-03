package main

import (
	"flag"
	"fmt"
	"log"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: example-cli echo --key=<key>")
		os.Exit(1)
	}

	command := os.Args[1]

	// Define flags
	key := flag.String("key", "", "Key for the PNS entry")

	// Parse flags from os.Args[2:] since os.Args[1] is the command
	flag.CommandLine.Parse(os.Args[2:])

	if *key == "" {
		log.Fatal("Error: --key is required")
	}
	switch command {
	case "echo":
		log.Printf("The input key is: %s\n", *key)
	default:
		log.Fatalf("Unknown command: %s", command)
	}
	os.Exit(0)
}
