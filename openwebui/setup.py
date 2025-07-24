#!/usr/bin/env python3
"""
CTF Web API Automation Script
Easily create multiple challenges with functions, models, and pipelines
"""

import requests
import json
import sys
import argparse
import re
from pathlib import Path
import time
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry
import os

class APIClient:
    def __init__(self, base_url):
        self.base_url = base_url
        self.session = requests.Session()
        self.token = None
        
        # Configure retry strategy
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)
        
        # Set default headers
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0",
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.5",
            "Origin": base_url,
            "Connection": "keep-alive"
        })
    
    def set_auth_token(self, token):
        """Set authentication token for subsequent requests"""
        self.token = token
        self.session.headers.update({
            "authorization": f"Bearer {token}"
        })
        self.session.cookies.set("token", token)
    
    def _parse_json_response(self, response, endpoint=""):
        """Safely parse JSON response, handling various edge cases"""
        try:
            return response.json()
        except json.JSONDecodeError:
            # For successful status codes with no/invalid JSON body
            if response.status_code in [200, 201, 204]:
                # Some endpoints return empty success responses
                return {"success": True, "status_code": response.status_code}
            
            # Log error details for debugging
            content_type = response.headers.get('content-type', '')
            content_length = response.headers.get('content-length', 'unknown')
            
            error_msg = f"Failed to parse JSON response from {endpoint}"
            error_msg += f"\n   Status: {response.status_code}"
            error_msg += f"\n   Content-Type: {content_type}"
            error_msg += f"\n   Content-Length: {content_length}"
            
            # Only show response preview for text content
            if 'text' in content_type or 'json' in content_type:
                preview = response.text[:200] if response.text else "(empty)"
                error_msg += f"\n   Response preview: {preview}"
            
            raise ValueError(error_msg)
    
    def post(self, endpoint, json_data=None, files=None, data=None, extra_headers=None):
        """Make a POST request with automatic error handling"""
        url = f"{self.base_url}{endpoint}"
        headers = {}
        
        # Only set Content-Type for JSON requests, not for multipart/form-data
        if json_data is not None and files is None:
            headers["Content-Type"] = "application/json"
        
        if extra_headers:
            headers.update(extra_headers)
        
        # When uploading files, requests will automatically set the correct Content-Type with boundary
        response = self.session.post(url, json=json_data, files=files, data=data, headers=headers, timeout=30)
        
        # Check for success
        if response.status_code not in [200, 201, 204]:
            error_msg = f"API request to {endpoint} failed with status {response.status_code}"
            try:
                error_detail = response.json()
                error_msg += f": {error_detail}"
            except:
                # Only show text preview if it's not binary data
                content_type = response.headers.get('content-type', '')
                if 'text' in content_type or 'json' in content_type:
                    error_msg += f": {response.text[:500]}"
                else:
                    error_msg += f" (binary response)"
            raise Exception(error_msg)
        
        return response
    
    def get(self, endpoint, params=None, extra_headers=None):
        """Make a GET request with automatic error handling"""
        url = f"{self.base_url}{endpoint}"
        headers = {}
        
        if extra_headers:
            headers.update(extra_headers)
        
        response = self.session.get(url, params=params, headers=headers, timeout=30)
        
        # Check for success
        if response.status_code not in [200, 201, 204]:
            error_msg = f"API request to {endpoint} failed with status {response.status_code}"
            try:
                error_detail = response.json()
                error_msg += f": {error_detail}"
            except:
                error_msg += f": {response.text}"
            raise Exception(error_msg)
        
        return response

def wait_for_service(base_url, max_retries=60, delay=5):
    """Wait for a service to become available"""
    print(f"⏳ Waiting for service at {base_url} to become ready...")
    
    session = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=0.3,
        status_forcelist=[500, 502, 503, 504]
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount('http://', adapter)
    
    for attempt in range(max_retries):
        try:
            # Try to access the API endpoint
            response = session.get(f"{base_url}/api/v1/auths", timeout=5)
            if response.status_code in [200, 401, 403, 404]:  # Any response means service is up
                print(f"✓ Service at {base_url} is ready!")
                return True
        except requests.exceptions.RequestException as e:
            if attempt % 10 == 0:  # Print status every 10 attempts
                print(f"   Attempt {attempt + 1}/{max_retries}: Service not ready yet...")
        
        time.sleep(delay)
    
    raise Exception(f"Service at {base_url} failed to become ready after {max_retries * delay} seconds")

def load_config(config_file):
    """Load configuration from JSON file"""
    try:
        with open(config_file, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"Error: Configuration file '{config_file}' not found")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in configuration file: {e}")
        sys.exit(1)

def read_file_content(filepath):
    """Read content from a file"""
    try:
        with open(filepath, 'r') as f:
            return f.read()
    except FileNotFoundError:
        print(f"Warning: File '{filepath}' not found - skipping")
        return None

def authenticate(client, config, signup_first=True, max_retries=3, retry_delay=5):
    """Authenticate with the API - try signup first, then signin with retries"""
    
    creds = config['credentials']
    endpoints = ["/api/v1/auths/signup", "/api/v1/auths/signin"] if signup_first else ["/api/v1/auths/signin"]
    
    for endpoint in endpoints:
        print(f"🔑 Attempting authentication via {endpoint.split('/')[-1]}...")
        
        for attempt in range(max_retries):
            try:
                data = {
                    "email": creds['email'],
                    "password": creds['password']
                }
                
                # Include name for signup
                if "signup" in endpoint:
                    data["name"] = creds['name']
                
                response = client.post(endpoint, json_data=data,
                                     extra_headers={"Accept": "*/*", "Priority": "u=0"})
                
                # Extract token from the set-cookie header
                set_cookie = response.headers.get('set-cookie', '')

                # Parse the token from the cookie string
                if 'token=' in set_cookie:
                    token = set_cookie.split('token=')[1].split(';')[0].strip()
                    print(f"✓ Authentication successful via {endpoint.split('/')[-1]}")
                    client.set_auth_token(token)
                    return token
                    
            except Exception as e:
                if attempt < max_retries - 1:
                    print(f"   ⚠️  Authentication attempt {attempt + 1}/{max_retries} failed: {e}")
                    print(f"   🔄 Retrying in {retry_delay} seconds...")
                    time.sleep(retry_delay)
                elif endpoint == endpoints[-1]:  # Last endpoint and last attempt
                    raise Exception(f"Authentication failed after {max_retries} attempts: {e}")
                else:
                    break  # Try next endpoint
    
    raise Exception("No token found in authentication response")

def configure_code_execution(client, config):
    """Configure code execution settings"""
    print("\n💻 Configuring Code Execution...")
    
    code_execution_config = config.get('code_execution_config')
    if not code_execution_config:
        print("   ℹ️  No code execution configuration found - skipping")
        return
    
    data = {
        "ENABLE_CODE_EXECUTION": code_execution_config.get('enable_code_execution', True),
        "CODE_EXECUTION_ENGINE": code_execution_config.get('code_execution_engine', 'jupyter'),
        "CODE_EXECUTION_JUPYTER_URL": code_execution_config.get('code_execution_jupyter_url'),
        "CODE_EXECUTION_JUPYTER_AUTH": code_execution_config.get('code_execution_jupyter_auth', 'token'),
        "CODE_EXECUTION_JUPYTER_AUTH_TOKEN": code_execution_config.get('code_execution_jupyter_auth_token'),
        "CODE_EXECUTION_JUPYTER_AUTH_PASSWORD": code_execution_config.get('code_execution_jupyter_auth_password', ''),
        "CODE_EXECUTION_JUPYTER_TIMEOUT": code_execution_config.get('code_execution_jupyter_timeout', 60),
        "ENABLE_CODE_INTERPRETER": code_execution_config.get('enable_code_interpreter', True),
        "CODE_INTERPRETER_ENGINE": code_execution_config.get('code_interpreter_engine', 'jupyter'),
        "CODE_INTERPRETER_PROMPT_TEMPLATE": code_execution_config.get('code_interpreter_prompt_template', ''),
        "CODE_INTERPRETER_JUPYTER_URL": code_execution_config.get('code_interpreter_jupyter_url'),
        "CODE_INTERPRETER_JUPYTER_AUTH": code_execution_config.get('code_interpreter_jupyter_auth', 'token'),
        "CODE_INTERPRETER_JUPYTER_AUTH_TOKEN": code_execution_config.get('code_interpreter_jupyter_auth_token'),
        "CODE_INTERPRETER_JUPYTER_AUTH_PASSWORD": code_execution_config.get('code_interpreter_jupyter_auth_password', ''),
        "CODE_INTERPRETER_JUPYTER_TIMEOUT": code_execution_config.get('code_interpreter_jupyter_timeout', 60)
    }
    
    client.post("/api/v1/configs/code_execution", json_data=data,
                extra_headers={"Priority": "u=0"})
    print("✓ Code execution configured")

def configure_signups(client):
    """Configure user signups"""
    #{"SHOW_ADMIN_DETAILS":true,"WEBUI_URL":"","ENABLE_SIGNUP":false,"ENABLE_API_KEY":true,"ENABLE_API_KEY_ENDPOINT_RESTRICTIONS":false,"API_KEY_ALLOWED_ENDPOINTS":"","DEFAULT_USER_ROLE":"pending","JWT_EXPIRES_IN":"-1","ENABLE_COMMUNITY_SHARING":true,"ENABLE_MESSAGE_RATING":true,"ENABLE_CHANNELS":false,"ENABLE_NOTES":true,"ENABLE_USER_WEBHOOKS":true,"PENDING_USER_OVERLAY_TITLE":"","PENDING_USER_OVERLAY_CONTENT":"","RESPONSE_WATERMARK":""}
    print("\n📝 Configuring User Signups...")
    data = {
        "SHOW_ADMIN_DETAILS": True,
        "WEBUI_URL": "",
        "ENABLE_SIGNUP": True,
        "ENABLE_API_KEY": True,
        "ENABLE_API_KEY_ENDPOINT_RESTRICTIONS": False,
        "API_KEY_ALLOWED_ENDPOINTS": "",
        "DEFAULT_USER_ROLE": "user",
        "JWT_EXPIRES_IN": "-1",  # No expiration
        "ENABLE_COMMUNITY_SHARING": False,
        "ENABLE_MESSAGE_RATING": False,
        "ENABLE_CHANNELS": False,
        "ENABLE_NOTES": False,
        "ENABLE_USER_WEBHOOKS": False,
        "PENDING_USER_OVERLAY_TITLE": "",
        "PENDING_USER_OVERLAY_CONTENT": "",
        "RESPONSE_WATERMARK": "",
    }

    try:
        client.post("/api/v1/auths/admin/config", json_data=data,
                    extra_headers={"Priority": "u=0"})
        print("✓ Signups configured")
    except Exception as e:
        print(f"✗ Failed to configure signups: {e}")
        raise

def create_users(client, config):
    """Create additional users"""
    print("\n👥 Creating Users")
    print("----------------")
    
    users = config.get('users', [])
    if not users:
        print("   ℹ️  No additional users to create")
        return 0
    
    created = 0
    for user in users:
        try:
            data = {
                "name": user['name'],
                "email": user['email'],
                "password": user['password'],
                "role": user.get('role', 'user')
            }
            
            client.post("/api/v1/auths/add", json_data=data,
                       extra_headers={"Priority": "u=0"})
            print(f"✓ User '{user['name']}' ({user['email']}) created with role: {user.get('role', 'user')}")
            created += 1
            
        except Exception as e:
            print(f"✗ Failed to create user '{user['name']}': {e}")
    
    return created

def create_function(client, function_config):
    """Create a single function"""
    print(f"\n📝 Creating function: {function_config['name']}")
    
    # Read function content
    content = read_file_content(function_config['content_file'])
    if content is None:
        return False
    
    data = {
        "id": function_config['id'],
        "name": function_config['name'],
        "meta": {
            "description": function_config['description']
        },
        "content": content
    }
    
    # Create function
    client.post("/api/v1/functions/create", json_data=data, 
                extra_headers={"Priority": "u=4"})
    print(f"✓ Function '{function_config['name']}' created")
    
    # Toggle if enabled
    if function_config.get('enabled', True):
        client.post(f"/api/v1/functions/id/{function_config['id']}/toggle", 
                    extra_headers={"Priority": "u=0"})
        print(f"✓ Function '{function_config['name']}' enabled")
    
    return True

def create_tool(client, tool_config):
    """Create a single tool"""
    print(f"\n🔧 Creating tool: {tool_config['name']}")
    
    # Read tool content
    content = read_file_content(tool_config['content_file'])
    if content is None:
        return False
    
    data = {
        "id": tool_config['id'],
        "name": tool_config['name'],
        "meta": {
            "description": tool_config.get('description', '')
        },
        "content": content,
        "access_control": tool_config.get('access_control', None)
    }
    
    # Create tool
    try:
        client.post("/api/v1/tools/create", json_data=data, 
                    extra_headers={"Priority": "u=0"})
        print(f"✓ Tool '{tool_config['name']}' created")
        return True
    except Exception as e:
        # Check if tool already exists
        if "already exists" in str(e):
            print(f"   ℹ️  Tool '{tool_config['name']}' already exists")
            return True
        raise

def get_knowledge_list(client):
    """Get list of existing knowledge bases"""
    try:
        response = client.get("/api/v1/knowledge/", extra_headers={"Accept": "application/json"})
        return response.json()
    except Exception as e:
        print(f"   ⚠️  Failed to get knowledge list: {e}")
        return []

def create_knowledge(client, name, description, access_control=None):
    """Create a new knowledge base"""
    data = {
        'name': name,
        'description': description,
        'access_control': access_control
    }
    
    try:
        response = client.post("/api/v1/knowledge/create", json_data=data,
                             extra_headers={"Priority": "u=0"})
        return response.json()
    except Exception as e:
        print(f"   ⚠️  Failed to create knowledge base: {e}")
        return None

def get_knowledge_id(client, name):
    """Get knowledge ID by name, create if doesn't exist"""
    knowledge_list = get_knowledge_list(client)
    
    # Look for existing knowledge base
    for knowledge in knowledge_list:
        if knowledge.get('name') == name:
            return knowledge.get('id')
    
    # Create new knowledge base if not found
    print(f"   📚 Creating new knowledge base: {name}")
    response = create_knowledge(client, name=name, description=name)
    if response and 'id' in response:
        return response['id']
    
    return None

def upload_file(client, file_path):
    """Upload a file to the system"""
    try:
        with open(file_path, 'rb') as f:
            files = {'file': (os.path.basename(file_path), f, 'application/octet-stream')}
            
            # Remove Content-Type and Accept-Encoding headers for multipart upload
            original_content_type = client.session.headers.get('Content-Type')
            original_accept_encoding = client.session.headers.get('Accept-Encoding')
            
            if 'Content-Type' in client.session.headers:
                del client.session.headers['Content-Type']
            if 'Accept-Encoding' in client.session.headers:
                del client.session.headers['Accept-Encoding']
            
            try:
                response = client.post("/api/v1/files/", files=files,
                                     extra_headers={"Accept": "application/json", "Priority": "u=0"})
                
                # Parse JSON response
                return client._parse_json_response(response, "/api/v1/files/")
                    
            finally:
                # Restore original headers if they existed
                if original_content_type:
                    client.session.headers['Content-Type'] = original_content_type
                if original_accept_encoding:
                    client.session.headers['Accept-Encoding'] = original_accept_encoding
                    
    except FileNotFoundError:
        print(f"   ⚠️  File not found: {file_path}")
        return None
    except Exception as e:
        print(f"   ⚠️  Failed to upload file {file_path}: {e}")
        return None

def add_file_to_knowledge(client, knowledge_id, file_id):
    """Add an uploaded file to a knowledge base"""
    data = {'file_id': file_id}
    
    try:
        response = client.post(f"/api/v1/knowledge/{knowledge_id}/file/add", 
                             json_data=data, extra_headers={"Priority": "u=0"})
        
        # Parse JSON response using helper
        return client._parse_json_response(response, f"/api/v1/knowledge/{knowledge_id}/file/add")
            
    except Exception as e:
        print(f"   ⚠️  Failed to add file to knowledge base: {e}")
        return None

def create_rag(client, rag_config):
    """Create RAG knowledge base and upload files"""
    print(f"\n📚 Creating RAG: {rag_config['name']}")
    
    # Get or create knowledge base
    knowledge_id = get_knowledge_id(client, rag_config['name'])
    if not knowledge_id:
        print(f"   ❌ Failed to get/create knowledge base '{rag_config['name']}'")
        return False
    
    print(f"   ✓ Using knowledge base ID: {knowledge_id}")
    
    # Upload files
    files = rag_config.get('files', [])
    if not files:
        print("   ℹ️  No files to upload")
        return True
    
    uploaded_count = 0
    for file_path in files:
        print(f"   📄 Uploading file: {file_path}")
        
        # Upload file
        upload_response = upload_file(client, file_path)
        if not upload_response:
            continue
        
        file_id = upload_response.get('id')
        if not file_id:
            print(f"   ⚠️  No file ID returned for {file_path}")
            continue
        
        print(f"   ✓ File uploaded with ID: {file_id}")
        
        # Add file to knowledge base
        add_response = add_file_to_knowledge(client, knowledge_id, file_id)
        if add_response:
            print(f"   ✓ File added to knowledge base")
            uploaded_count += 1
        else:
            print(f"   ⚠️  Failed to add file to knowledge base")
    
    print(f"   📊 Uploaded {uploaded_count}/{len(files)} files to RAG '{rag_config['name']}'")
    return uploaded_count > 0

def create_model(client, model_config):
    """Create a single model"""
    print(f"\n🤖 Creating model: {model_config['name']}")
    
    # Build meta object
    meta = {
        "profile_image_url": "/static/favicon.png",
        "description": model_config.get('description'),
        "suggestion_prompts": None,
        "tags": [],
        "capabilities": model_config.get('capabilities', {
            "vision": False,
            "file_upload": False,
            "web_search": False,
            "image_generation": False,
            "code_interpreter": False,
            "citations": False
        })
    }
    
    # Add filterIds if present
    if 'filter_ids' in model_config:
        meta['filterIds'] = model_config['filter_ids']
    
    # Add toolIds if present
    if 'toolIds' in model_config:
        meta['toolIds'] = model_config['toolIds']
    
    data = {
        "id": model_config['id'],
        "base_model_id": model_config['base_model_id'],
        "name": model_config['name'],
        "meta": meta,
        "params": {
            "system": model_config.get('system_prompt', '')
        },
        "access_control": model_config.get('access_control', None),
    }
    
    client.post("/api/v1/models/create", json_data=data, 
                extra_headers={"Priority": "u=0"})
    print(f"✓ Model '{model_config['name']}' created")
    
    # If model has tools, list them
    if 'toolIds' in model_config and model_config['toolIds']:
        print(f"   🔧 Tools enabled: {', '.join(model_config['toolIds'])}")
    
    return True

def enable_pipelines(client, config):
    """Enable the OpenAI pipeline configuration"""
    print("\n🔧 Configuring OpenAI pipeline...")
    
    pipelines_config = config['pipelines_config']
    
    data = {
        "ENABLE_OPENAI_API": True,
        "OPENAI_API_BASE_URLS": pipelines_config['base_urls'],
        "OPENAI_API_KEYS": pipelines_config['api_keys'],
        "OPENAI_API_CONFIGS": {}
    }
    
    # Build API configs dynamically
    for i in range(len(pipelines_config['base_urls'])):
        if i == 0:
            data["OPENAI_API_CONFIGS"][str(i)] = {}
        else:
            data["OPENAI_API_CONFIGS"][str(i)] = {
                "enable": True,
                "tags": [],
                "prefix_id": "",
                "model_ids": [],
                "connection_type": "external"
            }
    
    client.post("/openai/config/update", json_data=data, 
                extra_headers={"Priority": "u=0"})
    print("✓ OpenAI pipeline configured")

def upload_pipeline(client, pipeline_config):
    """Upload a single pipeline"""
    print(f"\n🚀 Uploading pipeline: {pipeline_config['name']}")
    
    content = read_file_content(pipeline_config['file'])
    if content is None:
        return False
    
    # Extract pipeline ID from the content if not provided
    pipeline_id = pipeline_config.get('id')
    if not pipeline_id:
        # Try to extract ID from the Python content
        id_match = re.search(r'self\.id\s*=\s*["\']([^"\']+)["\']', content)
        if id_match:
            pipeline_id = id_match.group(1)
            print(f"   ℹ️  Detected pipeline ID from content: {pipeline_id}")
    
    # Use the filename from the config
    filename = pipeline_config['name']
    if not filename.endswith('.py'):
        filename += '.py'
    
    # Prepare the files for multipart upload
    files = {
        'file': (filename, content, 'text/x-python')
    }
    
    # Prepare the form data
    # Note that this logic might need updated to dynamically determine the URL index
    # if we add more pipelines in the future
    data = {
        'urlIdx': '0'
    }
    
    # Important: Don't set Content-Type header - requests will set it automatically with boundary
    # Remove Content-Type from session headers temporarily if it exists
    original_content_type = client.session.headers.get('Content-Type')
    if 'Content-Type' in client.session.headers:
        del client.session.headers['Content-Type']
    
    max_retries = 5  # Maximum number of retries
    retry_delay = 10  # Seconds between retries
    
    try:
        for attempt in range(1, max_retries + 1):
            try:
                response = client.post("/api/v1/pipelines/upload", files=files, data=data,
                            extra_headers={"Accept": "*/*", "Priority": "u=0"})
                
                print(f"✓ Pipeline '{pipeline_config['name']}' uploaded successfully")
                
                # Extract pipeline ID from response if not provided
                if not pipeline_id and response:
                    try:
                        result = response.json()
                        pipeline_id = result.get('id')
                        if pipeline_id:
                            pipeline_config['id'] = pipeline_id  # Update config with actual ID
                    except:
                        pass
                
                # Configure pipeline valves if model_ids are specified
                # This should happen regardless of whether we had an ID originally
                if pipeline_id and 'model_ids' in pipeline_config:
                    # Make sure the config has the ID
                    if 'id' not in pipeline_config:
                        pipeline_config['id'] = pipeline_id
                    configure_pipeline_valves(client, pipeline_config)
                
                return True
                
            except Exception as e:
                # If pipeline already exists, try to just configure valves
                if "already exists" in str(e) and 'id' in pipeline_config and 'model_ids' in pipeline_config:
                    print(f"   ℹ️  Pipeline already exists, configuring valves...")
                    configure_pipeline_valves(client, pipeline_config)
                    return True
                
                # For other errors, retry if we haven't exhausted attempts
                if attempt < max_retries:
                    print(f"   ⚠️  Upload failed (attempt {attempt}/{max_retries}): {e}")
                    print(f"   🔄 Retrying in {retry_delay} seconds...")
                    time.sleep(retry_delay)
                else:
                    print(f"   ❌ Upload failed after {max_retries} attempts: {e}")
                    raise
        
        return False
        
    finally:
        # Restore original Content-Type if it existed
        if original_content_type:
            client.session.headers['Content-Type'] = original_content_type

def configure_pipeline_valves(client, pipeline_config):
    """Configure pipeline valves to tie pipeline to specific models"""
    print(f"   ⚙️  Configuring pipeline valves for: {pipeline_config['id']}")
    
    data = {
        "pipelines": pipeline_config['model_ids'],
        "priority": pipeline_config.get('priority', 0)
    }
    
    client.post(f"/api/v1/pipelines/{pipeline_config['id']}/valves/update?urlIdx=0", 
                json_data=data, extra_headers={"Priority": "u=0"})
    print(f"   ✓ Pipeline tied to models: {', '.join(pipeline_config['model_ids'])}")


def associate_knowledge_with_models(client, config):
    """Associate knowledge bases with models that need them"""
    
    # Get list of all knowledge bases
    knowledge_list = get_knowledge_list(client)
    knowledge_map = {k['name']: k for k in knowledge_list}
    
    # Find models that need knowledge bases
    models_with_knowledge = []
    for model in config.get('models', []):
        if 'knowledge_names' in model:
            models_with_knowledge.append(model)
    
    if not models_with_knowledge:
        print("   ℹ️  No models require knowledge base associations")
        return 0
    
    associated = 0
    for model in models_with_knowledge:
        try:
            print(f"\n   📚 Updating model '{model['name']}' with knowledge bases...")
            
            # Get current model data
            response = client.get(f"/api/v1/models/model?id={model['id']}", 
                                extra_headers={"Priority": "u=4"})
            model_data = client._parse_json_response(response, f"/api/v1/models/model?id={model['id']}")
            
            # Build knowledge array
            knowledge_items = []
            for knowledge_name in model['knowledge_names']:
                if knowledge_name in knowledge_map:
                    knowledge = knowledge_map[knowledge_name]
                    # Build knowledge item with required fields
                    knowledge_item = {
                        "id": knowledge['id'],
                        "user_id": knowledge['user_id'],
                        "name": knowledge['name'],
                        "description": knowledge.get('description', ''),
                        "data": knowledge.get('data', {"file_ids": []}),
                        "meta": knowledge.get('meta', None),
                        "access_control": knowledge.get('access_control', None),
                        "created_at": knowledge['created_at'],
                        "updated_at": knowledge['updated_at'],
                        "user": knowledge.get('user', {}),
                        "files": knowledge.get('files', []),
                        "type": "collection"
                    }
                    knowledge_items.append(knowledge_item)
                    print(f"      ✓ Found knowledge base: {knowledge_name}")
                else:
                    print(f"      ⚠️  Knowledge base not found: {knowledge_name}")
            
            if knowledge_items:
                # Update model meta with knowledge
                if 'meta' not in model_data:
                    model_data['meta'] = {}
                model_data['meta']['knowledge'] = knowledge_items
                
                # Send update request
                update_response = client.post(f"/api/v1/models/model/update?id={model['id']}", 
                                            json_data=model_data,
                                            extra_headers={"Priority": "u=0"})
                
                print(f"   ✓ Model '{model['name']}' updated with {len(knowledge_items)} knowledge base(s)")
                associated += 1
            
        except Exception as e:
            print(f"   ✗ Failed to associate knowledge with model '{model['name']}': {e}")
    
    return associated


def main():
    """Main execution function"""
    parser = argparse.ArgumentParser(description='CTF Web API Automation Script')
    parser.add_argument('-c', '--config', default='ctf_config.json', 
                       help='Configuration file path (default: ctf_config.json)')
    args = parser.parse_args()
    
    print("🏁 CTF Challenge Setup Script")
    print("============================\n")
    
    # Load configuration
    config = load_config(args.config)
    
    # Wait for service to be ready
    try:
        wait_for_service(config['base_url'])
    except Exception as e:
        print(f"✗ Service failed to become ready: {e}")
        sys.exit(1)
    
    # Create API client
    client = APIClient(config['base_url'])
    
    # Track statistics
    stats = {
        'functions': 0,
        'tools': 0,
        'models': 0,
        'pipelines': 0,
        'users': 0,
        'knowledge': 0,
        'knowledge_associations': 0
    }
    
    # Step 1: Authenticate
    try:
        print("🔐 Authenticating")
        print("-------------------")
        authenticate(client, config)
    except Exception as e:
        print(f"✗ Failed to authenticate: {e}")
        sys.exit(1)

    # Step 2: Configure code execution
    if config.get('code_execution_config'):
        try:
            configure_code_execution(client, config)
        except Exception as e:
            print(f"✗ Failed to configure code execution: {e}")

    # Step 3: Create additional users and configure signups
    print("\n👥 Configuring Users and Signups")
    if config.get('users'):
        stats['users'] = create_users(client, config)
    configure_signups(client)

    # Step 4: Create all functions
    print("\n📂 Creating Functions")
    print("-------------------")
    for func in config.get('functions', []):
        try:
            if create_function(client, func):
                stats['functions'] += 1
        except Exception as e:
            print(f"✗ Failed to create function '{func['name']}': {e}")
    
    # Step 5: Create all tools
    print("\n🔧 Creating Tools")
    print("---------------")
    for tool in config.get('tools', []):
        try:
            if create_tool(client, tool):
                stats['tools'] += 1
        except Exception as e:
            print(f"✗ Failed to create tool '{tool['name']}': {e}")

    # Step 6: Create RAG
    print("\n📚 Creating RAG Knowledge Bases")
    print("------------------------------")
    for knowledge in config.get('knowledge', []):
        try:
            if create_rag(client, knowledge):
                stats['knowledge'] += 1
        except Exception as e:
            print(f"✗ Failed to create RAG '{knowledge['name']}': {e}")
    
    # Step 7: Create all models
    print("\n🤖 Creating Models")
    print("----------------")
    for model in config.get('models', []):
        try:
            if create_model(client, model):
                stats['models'] += 1
        except Exception as e:
            print(f"✗ Failed to create model '{model['name']}': {e}")
    
    # Step 8: Associate knowledge bases with models
    print("\n🔗 Associating Knowledge Bases with Models")
    print("----------------------------------------")
    if any('knowledge_names' in model for model in config.get('models', [])):
        stats['knowledge_associations'] = associate_knowledge_with_models(client, config)
    
    # Step 9: Enable pipelines configuration
    if config.get('pipelines_config'):
        print("\n🔧 Enabling Pipelines Configuration")
        print("-------------------------")
        enable_pipelines(client, config)

    # Step 10: Upload pipelines
    if config.get('pipelines'):
        print("\n🚀 Uploading Pipelines")
        print("--------------------")
        for pipeline in config.get('pipelines', []):
            try:
                if upload_pipeline(client, pipeline):
                    stats['pipelines'] += 1
            except Exception as e:
                print(f"✗ Failed to upload pipeline '{pipeline['name']}': {e}")

    # Summary
    print("\n✅ CTF setup completed!")
    print("\n📊 Summary:")
    print(f"   - Users created: {stats['users']}/{len(config.get('users', []))}")
    print(f"   - Functions created: {stats['functions']}/{len(config.get('functions', []))}")
    print(f"   - Tools created: {stats['tools']}/{len(config.get('tools', []))}")
    print(f"   - Knowledge bases created: {stats['knowledge']}/{len(config.get('knowledge', []))}")
    print(f"   - Models created: {stats['models']}/{len(config.get('models', []))}")
    if stats['knowledge_associations'] > 0:
        print(f"   - Knowledge associations: {stats['knowledge_associations']}")
    print(f"   - Pipelines uploaded: {stats['pipelines']}/{len(config.get('pipelines', []))}")
    
    # Show pipeline-model associations
    if config.get('pipelines'):
        print("\n🔗 Pipeline-Model Associations:")
        for pipeline in config.get('pipelines', []):
            if 'model_ids' in pipeline:
                print(f"   - {pipeline['name']} → {', '.join(pipeline['model_ids'])}")
    
    # Show model-tool associations
    models_with_tools = [m for m in config.get('models', []) if 'toolIds' in m and m['toolIds']]
    if models_with_tools:
        print("\n🔧 Model-Tool Associations:")
        for model in models_with_tools:
            print(f"   - {model['name']} → {', '.join(model['toolIds'])}")
    
    # Show model-knowledge associations
    models_with_knowledge = [m for m in config.get('models', []) if 'knowledge_names' in m]
    if models_with_knowledge:
        print("\n📚 Model-Knowledge Associations:")
        for model in models_with_knowledge:
            print(f"   - {model['name']} → {', '.join(model['knowledge_names'])}")
    
    # Exit with error if any components failed
    total_expected = len(config.get('functions', [])) + len(config.get('tools', [])) + len(config.get('models', [])) + len(config.get('pipelines', [])) + len(config.get('knowledge', []))
    total_created = stats['functions'] + stats['tools'] + stats['models'] + stats['pipelines'] + stats['knowledge']
    if total_created < total_expected:
        sys.exit(1)

if __name__ == "__main__":
    main()