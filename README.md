# API Workbench - Local Proxy Agent

This is a lightweight, zero-dependency local proxy agent built in [V (Vlang)](https://vlang.io/). 
It acts as a transparent middleman, allowing your API Workbench frontend to bypass browser CORS restrictions and make complex, unrestricted REST API calls (including large file uploads and binary file downloads).

## Prerequisites
To compile the source code, you must have the V compiler installed. *(Note: Your end-users do **not** need V installed; they will just run the compiled binary).*
1. Download and install V from [vlang.io](https://vlang.io/).
2. Verify installation by running `v version` in your terminal.

## Compiling to an Executable

V compiles down to a single, tiny, lightning-fast binary with zero external dependencies.

1. Open your terminal in the directory containing `main.v`.
2. Run the following command:
   ```bash
   v -prod main.v
   ```
   *(The `-prod` flag strips debug symbols and optimizes the binary for size and speed).*

This will instantly generate a standalone executable file in the same directory:
- **Windows:** `main.exe`
- **Linux/macOS:** `main`

### Cross-Compiling (Optional)
V makes it extremely easy to build for other operating systems. If you are on Linux and want to compile a `.exe` for Windows users to download:
```bash
v -os windows -prod main.v
```

## Running the Proxy

Users simply double-click the executable or run it from the terminal:

```bash
./main
```
You will see the output: `API Proxy Agent is running on http://localhost:7777`

---

## Frontend Integration Guide

The frontend must send a `POST` request to `http://localhost:7777/makeapicall`. The proxy handles the rest transparently.

### 1. Request Configuration
Pass the actual target configuration via these custom HTTP Headers:
- `X-Target-Url`: The real API URL (e.g., `https://api.example.com/users`)
- `X-Target-Method`: The HTTP method (e.g., `GET`, `POST`, `PUT`)
- `X-Target-Headers`: A **JSON stringified object** of the headers the target API expects (like Authorization tokens).

**Example JavaScript Fetch (Upload & Request):**
```javascript
const formData = new FormData();
formData.append("file", myFile);

const response = await fetch("http://localhost:7777/makeapicall", {
    method: "POST", // The proxy ALWAYS receives a POST
    body: formData, // Natively pass FormData, JSON, or Blob here!
    headers: {
        "X-Target-Url": "https://api.github.com/upload",
        "X-Target-Method": "PUT",
        "X-Target-Headers": JSON.stringify({
            "Authorization": "Bearer YOUR_TOKEN"
        })
    }
});
```

### 2. Response Handling
The proxy is 100% transparent. It returns the exact **Status Code**, **Content-Type**, and **Raw Body Data** from the target server.

To read the target server's raw response headers (like rate limit tracking or custom tokens), you must decode the Base64 string that the proxy attaches:
```javascript
// 1. Get the real status code
console.log("Target API Status:", response.status); 

// 2. Decode the target API's raw headers
const b64Headers = response.headers.get("X-Proxy-Headers-Base64");
if (b64Headers) {
    const rawHeaders = atob(b64Headers); // Decode Base64 to string
    console.log("Target API Headers:\n", rawHeaders);
}

// 3. Process the response body natively
const contentType = response.headers.get("Content-Type");
if (contentType.includes("application/json")) {
    const data = await response.json();
} else if (contentType.includes("image/")) {
    const blob = await response.blob();
    // Do something with the image file
}
```
