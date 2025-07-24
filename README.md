# Open WebUI CTF - Docker Setup

This project provides a complete Capture The Flag (CTF) environment based on Open WebUI with LLM prompt injection challenges.

## 🚀 Quick Start

### Prerequisites
- Ubuntu 20.04/22.04/24.04 or Debian-based Linux (for automatic setup)
- At least 8GB of RAM available
- 20GB of free disk space (for models and containers)
- (Optional BUT HIGHLY RECOMMENDED) NVIDIA GPU for better performance

### Setup Instructions

1. **Clone the repository** (or ensure all files are in place):
   ```bash
   # Your project structure should look like:
   openwebui_ctf/
   ├── docker-compose.yml
   ├── Dockerfile.jupyter
   ├── Dockerfile.ollama
   ├── Dockerfile.openwebui
   ├── Dockerfile.setup
   ├── README.md
   ├── setup.sh
   ├── .env
   └── openwebui/
       ├── ctf_config_template.json
       ├── setup.py
       ├── functions/
       │   ├── input_filter.py
       │   └── output_filter.py
       ├── pipelines/
       │   └── prompt_guard.py
       └── tools/
           └── calculator.py
           

   ```

2. **Install Pre-requisites**:
   To install Docker, GPU drivers, and other prerequisites, run the following:
   ```bash
   ./setup -a -n
   ```
   After setup is completed, you will need to reboot.

3. **Configure the CTF Environment**:
   After install the pre-requisites and rebooting, run:
   ```bash
   ./setup --ctf
   ```

4. **Wait for services to be ready** (about 2-3 minutes), then check status:
   ```bash
   docker compose logs -f ctf-setup  # Watch setup progress
   ```

5. **Access the CTF**:
   - Open WebUI: http://localhost:4242
   - Admin User: `admin@ctf.local` / `ctf_admin_password`
   - Standard User: `ctf@ctf.local` / `Hellollmworld!`

6. **Modifying the flags and credentials**
   The `.env` file contains all of the flags, credentials, and other settings

7. **Modifying the system prompts**
   The system prompts for each challenge can be found in `openwebui/ctf_config.json.template`.
   Be careful not to modify the placeholder for the flags.

8. **Adding/modifying challenges**
   The challenges are also found in `openwebui/ctf_config.json.template`.


## 🎯 CTF Challenges

The CTF includes 9 challenges:

1. **Challenge 1: Hello prompt injection!** - Basic prompt injection
2. **Challenge 2: System Prompt Protection** - Bypass system prompt protections
3. **Challenge 3: Input Filtering** - Defeat input filters
4. **Challenge 4: Output Filtering** - Bypass output filters
5. **Challenge 5: LLM Prompt Guard** - Defeat ML-based prompt injection detection
6. **Challenge 6: All Defenses** - Defeat all of the prior defenses applied to on model
7. **Challenge 7: Code Interpreter** - Find the flag on disk using code execution via the interpreter
8. **Challenge 8: Calculator Agent** - Abuse the calculator to find the flag on disk
9. **Challenge 9: RAG** - Find the flag in the documents


## 🛠️ Service Details

| Service | Port | Description |
|---------|------|-------------|
| Open WebUI | 4242 | Main CTF interface |
| Ollama | 11434 | LLM model server |
| Pipelines | 9099 | Custom processing pipelines |
| Jupyter | 8888 | Code execution environment |

## 📝 Managing the CTF

### View logs:
```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f open-webui
```

### Restart services:
```bash
docker compose restart
```

### Reset the CTF:
```bash
docker compose down -v  # Remove all data
docker compose up -d    # Start fresh
```

### Stop everything:
```bash
docker compose down
```

## 🔧 Troubleshooting

### No GPU / CPU-Only Mode
The CTF can run without a GPU but it will be very, very slow.

### GPU Support Issues

### Model Download Issues
If the Llama model fails to download:
```bash
docker exec -it ollama ollama pull llama3.1:8b
```

### Setup Script Failures
Check the setup logs:
```bash
docker compose logs ctf-setup
```

If setup fails, you can run it manually:
```bash
docker compose run --rm ctf-setup
```

### Port Conflicts
If ports are already in use, modify the `.env` file to change port mappings.

## 🏁 CTF Flag Locations

Without spoiling the challenges, here's where flags are stored:
- Challenges 1-6: In the system prompts of each model
- Challenge 7: In the Jupyter container filesystem
- Challenge 8: In the open-webui container filesystem
- Challenge 9: In one of the RAG documents

## 👥 Creating Additional Users
By default, users can sign themselves up.

To add more CTF participants as part of the automation process, modify `openwebui/ctf_config_template.json` and add users to the `users` array, then re-run the setup:
```bash
docker compose run --rm ctf-setup
```

## 📚 Resources

- [Open WebUI Documentation](https://github.com/open-webui/open-webui)
- [Ollama Documentation](https://ollama.ai/)
- [LLM Security Resources](https://github.com/llm-security)

Good luck with the CTF! 🚩
