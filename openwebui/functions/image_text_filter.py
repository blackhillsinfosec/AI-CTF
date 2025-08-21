"""
title: image_text_filter
author: open-webui
author_url: Brian Fehrman
version: 0.1
"""

from pydantic import BaseModel, Field
from typing import Optional


class Filter:
    class Valves(BaseModel):
        priority: int = Field(
            default=0, description="Priority level for the filter operations."
        )
        pass

    class UserValves(BaseModel):

        pass

    def __init__(self):
        # Indicates custom file handling logic. This flag helps disengage default routines in favor of custom
        # implementations, informing the WebUI to defer file-related operations to designated methods within this class.
        # Alternatively, you can remove the files directly from the body in from the inlet hook
        # self.file_handler = True

        # Initialize 'valves' with specific configurations. Using 'Valves' instance helps encapsulate settings,
        # which ensures settings are managed cohesively and not confused with operational flags like 'file_handler'.
        self.valves = self.Valves()
        pass

    def strip_text(self, content):
        """
        Processes a JSON object to handle text and image fields.

        - If both text and image fields are present, it removes the text field, keeping only the image.
        - If only a text field is present, it replaces the text with a specific message.

        Args:
            content (list or string): A list or string containing message content.

        Returns:
            list or string: The modified content.
        """

        response_message = "Respond only with: Please provide an image for processing"

        if not content or isinstance(content, str):
            return response_message

        # Check for the presence of text and image types
        has_text = any(item["type"] == "text" for item in content)
        has_image = any(item["type"] == "image_url" for item in content)

        # Scenario 1: Both text and image are present, so keep only the image content.
        if has_text and has_image:
            # Create a new list containing only image items
            content = [item for item in content if item["type"] == "image_url"]
            return content

        # Scenario 2: Only text is present, so replace the text.
        if has_text and not has_image:
            for item in content:
                if item["type"] == "text":
                    item["text"] = response_message
            return content

        return content

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        # Modify the request body or validate it before processing by the chat completion API.
        # This function is the pre-processor for the API where various checks on the input can be performed.
        # It can also modify the request before sending it to the API.
        print(f"inlet:{__name__}")
        print(f"inlet:body:{body}")
        print(f"inlet:user:{__user__}")

        messages = body["messages"][-1:]
        messages[0]["content"] = self.strip_text(messages[0]["content"])
        body = {**body, "messages": messages}
        return body
