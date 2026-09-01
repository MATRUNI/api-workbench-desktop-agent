# API Workbench - Local Proxy Agent

This is a lightweight, zero-dependency local proxy agent built in [V (Vlang)](https://vlang.io/). 
It acts as a transparent middleman, allowing your API Workbench frontend to bypass browser CORS restrictions and make complex, unrestricted REST API calls (including large file uploads and binary file downloads).

## 🚀 Quick Start (Pre-compiled Binaries)

You do not need to install any dependencies to run the proxy. Simply download the standalone executable for your operating system from the **Releases** tab. The binaries are extremely small and fast:

- **Linux** (`api-proxy-linux`): ~314 KB
- **macOS** (`api-proxy-macos`): ~574 KB
- **Windows** (`api-proxy-windows.exe`): ~741 KB

### Running on Linux / macOS
1. Open your terminal and navigate to where you downloaded the file.
2. Make the file executable:
   ```bash
   # For Linux
   chmod +x api-proxy-linux

   # For macOS
   chmod +x api-proxy-macos
   ```
3. Run the proxy agent:
   ```bash
   # For Linux
   ./api-proxy-linux

   # For macOS
   ./api-proxy-macos
   ```

### Running on Windows
1. Open the folder where you downloaded `api-proxy-windows.exe`.
2. Double-click the executable, or run it from the Command Prompt / PowerShell:
   ```cmd
   api-proxy-windows.exe
   ```

Upon running, you should see the output: `Streaming API Proxy (Raw TCP Chunked) is running on http://localhost:7777`.

*(Note: You can run the proxy on a custom port by passing it as an argument, e.g., `./api-proxy-linux 8080` or `api-proxy-windows.exe 8080`)*

---

## 🛠️ Build from Source

If you prefer to compile the source code yourself, you must have the [V compiler](https://vlang.io/) installed.

### 1. Clone the Repository
```bash
git clone https://github.com/YOUR_USERNAME/api-workbench-desktop-agent.git
cd api-workbench-desktop-agent
```

### 2. Compile to an Executable
V compiles down to a single, tiny binary with zero external dependencies. Run the following command to apply extreme size optimizations:

```bash
v -prod -skip-unused -cflags "-Os -flto -s" main.v
```

This will instantly generate a standalone executable file in the same directory:
- **Windows:** `main.exe`
- **Linux/macOS:** `main`

*(Note: If you are on Windows, you might want to omit the UPX/LTO flags if they trigger false-positives in Windows Defender: `v -prod -skip-unused -cflags "-Os -s" main.v`)*

### 3. Run the Proxy
```bash
# Linux / macOS
./main

# Windows
main.exe
```

---

## ✨ Key Features & Technical Achievements

- **Raw TCP Chunked Streaming:** Directly pipes byte streams between the client and the target server in real-time, resulting in zero memory bloat, even when proxying multi-gigabyte files.
- **100% Transparent Proxying:** Passes HTTP methods, headers, statuses, and body data natively. No base64 encoding or manual header parsing required.
- **Bypasses CORS Natively:** Automatically intercepts `OPTIONS` preflight requests and injects the proper `Access-Control-Allow-*` headers into the target server's response stream.
- **Ultra-Lightweight & Fast:** Built in **Vlang (V)**. Compiles to an extremely small binary (< 1MB) with **zero external dependencies**. Uses a minimal CPU and RAM footprint.
- **Cross-Platform & CI/CD Automated:** Available as a standalone executable for Linux, macOS, and Windows, fully automated via GitHub Actions with UPX compression.
- **Dynamic Configuration:** Run on any port without recompiling just by passing it as an argument (e.g., `./api-proxy-linux 8080`).

---

## 💻 Frontend Integration Guide

Using the proxy is incredibly simple. Just make your HTTP request exactly as you would to the actual API, but change the URL to the proxy and provide the real destination in the `X-Target-Url` header.

### Request Configuration
- Change your `fetch` URL to `http://localhost:7777/` (or whichever path your actual API expects, the proxy resolves it properly).
- Add the `X-Target-Url` header with your actual endpoint.
- Keep your HTTP method (`GET`, `POST`, `PUT`, etc.) and any other headers (`Authorization`, `Content-Type`) exactly the same! The proxy automatically forwards them natively.

**Example JavaScript Fetch (Upload & Request):**
```javascript
const formData = new FormData();
formData.append("file", myFile);

const response = await fetch("http://localhost:7777", {
    method: "PUT", // Use the actual HTTP method!
    body: formData, // Natively pass FormData, JSON, or Blob here
    headers: {
        "X-Target-Url": "https://api.github.com/upload",
        "Authorization": "Bearer YOUR_TOKEN" // Proxy forwards this natively
    }
});
```

### Response Handling
Because the proxy operates at the TCP layer, the response is exactly what the target server sent back. There is no base64 decoding required. You can read the status codes, headers, and body streams directly!

```javascript
// 1. Get the real status code
console.log("Target API Status:", response.status); 

// 2. Read the target API's raw headers directly
console.log("Rate Limit:", response.headers.get("X-RateLimit-Remaining"));

// 3. Process the response body natively
const contentType = response.headers.get("Content-Type") || "";
if (contentType.includes("application/json")) {
    const data = await response.json();
    console.log(data);
} else if (contentType.includes("image/")) {
    const blob = await response.blob();
    // Render the image directly
}
```
