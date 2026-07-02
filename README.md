# Open WebUI CTF - Docker Setup

This project provides a complete Capture The Flag (CTF) environment based on Open WebUI with LLM prompt injection challenges.

## 🚀 Quick Start

### Prerequisites
- Ubuntu 20.04/22.04/24.04 (for automatic setup)
- At least 8GB of RAM available
- 20GB of free disk space (for models and containers)
- (Optional BUT HIGHLY RECOMMENDED) NVIDIA GPU for better performance

### Setup Instructions

1. **Clone the repository** (or ensure all files are in place):

    ```bash
   # Your project structure should look like:
   openwebui_ctf/
   ├── .env
   ├── Dockerfile.ctfsetup
   ├── Dockerfile.jupyter
   ├── Dockerfile.ollama
   ├── Dockerfile.openwebui
   ├── README.md
   ├── docker-compose.yml
   ├── docker-compose.override.yml
   ├── setup.sh
   └── openwebui/
       ├── functions/
       │   ├── flag_check_filter.py.template
       │   ├── image_text_filter.py
       │   ├── input_filter.py
       │   ├── output_filter.py.template
       │   └── output_filter_2.py.template
       ├── knowledge/
       │   ├── stargate_secret.txt.template
       │   └── stargate_users.txt
       ├── pipelines/
       │   ├── email_summarizer.py.template
       │   └── prompt_guard.py
       └── tools/
       │   └── calculator.py
       ├── ctf_config.json.template
       ├── run_setup.sh
       └── setup.py

   ```

3. **Install Pre-requisites**:

   To install Docker, GPU drivers, and other prerequisites, run the following:
   ```bash
   ./setup -a -n
   ```
   After setup is completed, you will need to reboot.

4. **Configure the CTF Environment**:

   After installing the pre-requisites and rebooting, run:
   ```bash
   ./setup --ctf
   ```

5. **Wait for services to be ready** (about 2-3 minutes), then check status:

   ```bash
   docker compose logs -f ctf-setup  # Watch setup progress
   ```

7. **Access the CTF**:
   - Open WebUI: http://localhost:4242
   - Admin User: `admin@ctf.local` / `ctf_admin_password`
   - Standard User: `ctf@ctf.local` / `Hellollmworld!`

8. **Modifying the flags and credentials**

   The `.env` file contains all of the flags, credentials, and other settings.

   Note that files containing flag placeholders (e.g. ${CTF_CHALLENEGE_FLAG_1) end in .template. These files will be dynamically updated during the setup process. The flag placeholders are replaced with the corresponding flags in the .env file.

10. **Modifying the system prompts**

    The system prompts for each challenge can be found in `openwebui/ctf_config.json.template`.
   
    Be careful not to modify the placeholder for the flags.

11. **Adding/modifying challenges**

    The challenges are also found in `openwebui/ctf_config.json.template`.


## 🎯 CTF Challenges

The CTF includes 11 challenges:

1. **Challenge 1: Hello prompt injection!** - Basic prompt injection
2. **Challenge 2: System Prompt Protection** - Bypass system prompt protections
3. **Challenge 3: Input Filtering** - Defeat input filters
4. **Challenge 4: Output Filtering** - Bypass output filters
5. **Challenge 5: LLM Prompt Guard** - Defeat ML-based prompt injection detection
6. **Challenge 6: All Defenses** - Defeat all of the prior defenses applied to on model
7. **Challenge 7: Code Interpreter** - Find the flag on disk using code execution via the interpreter
8. **Challenge 8: Calculator Agent** - Abuse the calculator to find the flag on disk
9. **Challenge 9: RAG** - Find the flag in the documents
10. **Challenge 10: Email Summarizer** - Trick the email summarizer into sending an email to a target, which will give you the flag
10. **Challenge 11: Multi-Modal** - Use a method other than text to retrieve the flag

## 🚩 Checking Flags

The CTF has a model that users can use to check if a flag is correct.

The model is **Flag Checker** and can be selected just like any of the challenges can be.

Send a potential flag as a prompt and it will tell you if it was correct or not.

This model is templated, so it is dynamically updated when flags are changed in the .env file.

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

### Error Message when Entering a Prompt
Sometimes you might receive an error message (typically about JSON parsing or unexpected characters) when entering a prompt to one of the challenges. Logging out and logging back in seems to clear the issue in most cases. We will investigate this error further.

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

### Pinned image versions (do not use latest/main)
The OpenWebUI and Ollama base images are pinned on purpose:
- `Dockerfile.openwebui` → `open-webui:0.9.6`. OpenWebUI 0.10.x reworked model
  access control and moved response text into a structured `output` field. That
  hides challenges from regular users and breaks the Challenge 10 email
  summarizer (its filter rewrites `content`, which 0.10 no longer displays).
- `Dockerfile.ollama` → `ollama:0.24.0`. The Ollama 0.30.x series dropped the
  `mllama` architecture used by `llama3.2-vision:11b` (Challenge 11), failing
  with `unknown model architecture: 'mllama'`.

If you bump either image, re-verify all challenges first — regular-user model
visibility relies on `BYPASS_MODEL_ACCESS_CONTROL=true` in `docker-compose.yaml`.

## 🏁 CTF Flag Locations

Without spoiling the challenges, here's where flags are stored:
- Challenges 1-6: In the system prompts of each model
- Challenge 7: In the Jupyter container filesystem
- Challenge 8: In the open-webui container filesystem
- Challenge 9: In one of the RAG documents
- Challenge 10: The flag will be returned if the email summarizer sends a specific email to a target recipient
- Challenge 11: In the system prompt of the model

## 👥 Creating Additional Users
By default, users can sign themselves up.

To add more CTF participants as part of the automation process, modify `openwebui/ctf_config.json.template` and add users to the `users` array, then re-run the setup:
```bash
docker compose run --rm ctf-setup
```

## 📚 Resources

- [Open WebUI Documentation](https://github.com/open-webui/open-webui)
- [Ollama Documentation](https://ollama.ai/)
- [LLM Security Resources](https://github.com/llm-security)

Good luck with the CTF! 🚩
