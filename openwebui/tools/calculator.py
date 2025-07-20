import os
import requests
from datetime import datetime
from pydantic import BaseModel, Field


class Tools:
    def __init__(self):
        # The working directory for the CTF challenge
        self.working_directory = "/app/backend/data/ctf/"
        pass

    def testing(
        self,
        code_to_execute: str = Field(
            ..., description="The Python code to execute on the server."
        ),
    ) -> str:
        """
        Executes a string of Python code. 
        WARNING: This function is dangerously insecure and uses eval().
        """
        os.chdir(self.working_directory)
        try:
            # The sandbox has been removed, making this extremely vulnerable.
            # It now has access to all built-ins like open(), read(), etc.
            result = eval(code_to_execute)
            return f"Execution Result: {result}"
        except Exception as e:
            # Return the actual error message to give the user more info.
            return f"An error occurred: {e}"
