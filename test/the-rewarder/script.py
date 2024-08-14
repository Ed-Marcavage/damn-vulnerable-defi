import json

#   deployer 0xaE0bDc4eEAC5E950B67C6819B118761CaAF61946
#   alice 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6
#   player 0x44E97aF4418b7a17AABD8090bEA0A471a366305C
#   recovery 0x73030B99950fB19C6A813465E58A0BcA5487FBEa

#The index of address 0x44E97aF4418b7a17AABD8090bEA0A471a366305C is: 188

path = '/Users/edmarcavage/Documents/Development2024/audix/Audits/cyfrin/damn-vulnerable-defi/test/the-rewarder/dvt-distribution.json'
# The address to search for
target_address = "0x44E97aF4418b7a17AABD8090bEA0A471a366305C"

# Load the JSON file
with open(path, 'r') as file:
    data = json.load(file)

# Function to find the index of the target address
def find_address_index(address):
    for index, entry in enumerate(data):
        if entry['address'].lower() == address.lower():
            return index
    return -1  # Return -1 if the address is not found

# Find and print the index
result = find_address_index(target_address)
if result != -1:
    print(f"The index of address {target_address} is: {result}")
else:
    print(f"Address {target_address} not found in the JSON file.")