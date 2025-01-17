# config_utils.py


def find_block_bounds(config_name, lines):
    start_index = None
    open_brackets = 0

    # Locate the start of the block
    for i, line in enumerate(lines):
        if line.strip().startswith(config_name):
            start_index = i
            open_brackets += line.count("(") + line.count("{")
            break

    # If the block start is found, find the end of the block
    if start_index is not None:
        for i in range(start_index + 1, len(lines)):
            open_brackets += lines[i].count("(") + lines[i].count("{")
            open_brackets -= lines[i].count(")") + lines[i].count("}")
            if open_brackets == 0:  # Block is fully closed
                return start_index, i

    return None, None  # Block not found or not properly closed


# the following function is for simple configurations like: WEBSSO_ENABLED = True & WEBSSO_INITIAL_CHOICE = "demoidp-websso"
def ensure_simple_config(config_name, config_value, file_path):
    with open(file_path, "r") as file:
        lines = file.readlines()

    # Check if the configuration already exists
    config_exists = any(line.strip().startswith(f"{config_name} =") for line in lines)

    if not config_exists:
        with open(file_path, "a") as file:
            if config_name.lower() == "WEBSSO_INITIAL_CHOICE".lower():
                file.write(f"\n{config_name} = \"{config_value}\"\n")
            else:
                file.write(f"\n{config_name} = {config_value}\n")
        print(f"Added configuration: {config_name}")
    else:
        print(f"Configuration {config_name} already exists.")
