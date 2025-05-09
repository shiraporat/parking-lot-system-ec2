import uuid
import math
from flask import Flask, request, jsonify
from datetime import datetime, timedelta

app = Flask(__name__)

parking_tickets = {}

HOURLY_RATE = 10.00 

def calculate_charge(entry_time, exit_time):
    duration = exit_time - entry_time
    total_minutes = duration.total_seconds() / 60

    # Calculate the number of 15-minute increments and rounding up
    increments = math.ceil(total_minutes / 15)

    # Calculate the charge: Each 15-min increment costs $10/4 = $2.50
    charge = increments * (HOURLY_RATE / 4)
    return charge, duration

def format_duration(duration):
    total_seconds = int(duration.total_seconds())
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    return f"{hours} hours, {minutes} minutes, {seconds} seconds"

@app.route('/entry', methods=['POST'])
def vehicle_entry():
    plate = request.args.get('plate')
    parking_lot = request.args.get('parkingLot')

    if not plate or not parking_lot:
        return jsonify({"error": "Missing 'plate' or 'parkingLot' query parameter"}), 400

    ticket_id = str(uuid.uuid4())

    # Record entry time
    entry_time = datetime.now()

    parking_tickets[ticket_id] = {
        'plate': plate,
        'parkingLot': parking_lot,
        'entryTime': entry_time
    }

    print(f"Vehicle entered: Plate={plate}, Lot={parking_lot}, Ticket={ticket_id}, Time={entry_time}")
    print(f"Current tickets: {parking_tickets}") 

    return jsonify({"ticketId": ticket_id}), 200

@app.route('/exit', methods=['POST'])
def vehicle_exit():
    ticket_id = request.args.get('ticketId')

    if not ticket_id:
        return jsonify({"error": "Missing 'ticketId' query parameter"}), 400

    # Find the ticket in our storage
    ticket_info = parking_tickets.get(ticket_id)

    if not ticket_info:
        return jsonify({"error": "Invalid or expired ticket ID"}), 404 # Not Found

    # Record exit time
    exit_time = datetime.now()
    entry_time = ticket_info['entryTime']

    # Calculate charge and duration
    charge, duration = calculate_charge(entry_time, exit_time)
    formatted_duration = format_duration(duration)

    response_data = {
        "licensePlate": ticket_info['plate'],
        "totalParkedTime": formatted_duration, 
        "parkingLotId": ticket_info['parkingLot'],
        "charge": f"${charge:.2f}" 
    }

    print(f"Vehicle exited: Ticket={ticket_id}, Plate={ticket_info['plate']}, Charge=${charge:.2f}, Duration={formatted_duration}")
    # Remove the ticket from storage after exit
    del parking_tickets[ticket_id]
    print(f"Remaining tickets: {parking_tickets}") 

    return jsonify(response_data), 200

# Run the Flask app
if __name__ == '__main__':
    # Use 0.0.0.0 to make it accessible on the network
    # Use a port like 8080 or 5000
    app.run(host='0.0.0.0', port=8080, debug=True) # Turn debug=False for production
