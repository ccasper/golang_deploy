package main

import (
	"app/internal/common"
	"flag"
	"fmt"
	"log"
	"net/http"

	"github.com/go-chi/chi"
	"github.com/go-chi/chi/middleware"
	g "maragu.dev/gomponents"
	. "maragu.dev/gomponents/html"
)

var timezones = []string{
	"Local",
	"UTC",
	"America/New_York",
	"America/Chicago",
	"America/Los_Angeles",
	"Europe/London",
	"Asia/Tokyo",
	"Australia/Sydney",
}

func main() {
	ip := flag.String("ip", "", "IP to listen on")
	port := flag.Int64("port", PORT, "port to listen on")
	healthPort := flag.Int64("health_port", HEALTH_PORT, "port to listen on")

	flag.Parse()

	d := &common.SystemdDaemon{}

	// We call runMain so we can do dependency injection unit testing on runMain.
	// Consider passing in a http object to improve unit testing.
	runMain(d, *ip, *port, *healthPort)
}

func runMain(d common.DaemonNotifier, ip string, port int64, healthPort int64) {

	// Watchdog informing systemd to restart the task if we stall for too long.
	// This only works when the task is run under systemd.
	common.EnableBackgroundWatchdog(d)

	// Health port for checking the health and load of the task.
	// Used by deb packaging to ensure the task is healthy before marking the install successful.
	common.StartHealthServer(NAME, VERSION, fmt.Sprintf("%s:%d", ip, healthPort))
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Routes
	r.Get("/", homeHandler)

	// Static files
	fileServer := http.StripPrefix("/static/", http.FileServer(http.Dir("static")))
	r.Handle("/static/*", fileServer)

	addr := fmt.Sprintf("%s:%d", ip, port)
	log.Printf("Starting server on %s...", addr)

	log.Fatal(http.ListenAndServe(addr, r))
}

func homeHandler(w http.ResponseWriter, r *http.Request) {
	page := HTML(
		Head(
			Title("Golang Timezone Clock"),
			Meta(Name("viewport"), Content("width=device-width, initial-scale=1")),
			Script(Src("https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"), Defer()),
			Script(Src("https://cdn.tailwindcss.com")),
		),

		Body(
			Class("min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-600 via-indigo-600 to-purple-600 text-gray-900 font-sans"),

			// Main centered container
			Div(
				Class("bg-white/90 backdrop-blur-lg rounded-2xl shadow-2xl border border-white/30 p-10 max-w-md w-full text-center"),

				H1(
					Class("text-4xl font-bold text-gray-800 mb-6"),
					g.Text("🕒 Timezone Clock"),
				),

				Div(
					g.Attr("x-data", `{
						time: '',
						timezone: 'Local',
						updateTime() {
							let now = new Date();
							let options = { timeZone: this.timezone === 'Local' ? Intl.DateTimeFormat().resolvedOptions().timeZone : this.timezone, hour12: false };
							this.time = new Intl.DateTimeFormat('en-US', { ...options, timeStyle: 'medium', dateStyle: 'medium' }).format(now);
						},
						init() {
							this.updateTime();
							setInterval(() => this.updateTime(), 1000);
						}
					}`),

					// Dropdown selector
					Div(
						Class("mb-6 text-left"),
						Label(
							Class("block text-gray-700 font-semibold mb-2"),
							For("timezone"),
							g.Text("Select Timezone"),
						),
						Select(
							ID("timezone"),
							Class("w-full rounded-lg bg-white px-3 py-2 text-gray-800 shadow-sm border border-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-400 transition"),
							g.Attr("x-model", "timezone"),
							g.Attr("x-on:change", "updateTime()"),
							g.Map(timezones, func(tz string) g.Node {
								return Option(Value(tz), g.Text(tz))
							}),
						),
					),

					// Time display
					Div(
						Class("text-3xl font-mono text-blue-700 font-semibold mt-8"),
						g.Raw(`<span x-text="time"></span>`),
					),
				),

				// Footer
				Div(
					Class("mt-10 text-sm text-gray-500"),
					g.Text("Built with Go, gomponents, Alpine.js & Tailwind CSS"),
				),
			),
		),
	)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := page.Render(w); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}
