from flask import Flask, jsonify
import subprocess
import time

app = Flask(__name__)

# Function to check the status of the lokinet-vpn command
def check_lokinet_status():
    try:
        # Run the command and capture its output
        result = subprocess.run(['lokinet-vpn', '--status'], capture_output=True, text=True)
        output = result.stdout.strip()

        print(output)
        # Check if the output indicates that no exits are available
        return "::/0 via" in output.lower()

    except Exception as e:
        print("Error occurred while checking lokinet status:", e)
        return False

# Endpoint to check if Lokinet exits are available
@app.route('/status')
def lokinet_status():
    # Poll the Lokinet status for a maximum of 60 seconds
    max_poll_attempts = 6
    poll_interval = 10  # seconds
    for attempt in range(max_poll_attempts):
        if check_lokinet_status():
            return jsonify({'status': 'Lokinet exits are available'}), 200
        else:
            time.sleep(poll_interval)
    return jsonify({'status': 'No Lokinet exits available'}), 503

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
