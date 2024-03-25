import functions_framework
from google.cloud import storage
from google.cloud import bigquery
import fastavro
from io import BytesIO

bucket_name = "my-datastream-data"


def split_flight_details(detail):
    flight_date, flight_number, travel, flight_class, distance = detail.split("//")
    origin, destination = travel.split('-')
    return flight_date, flight_number, flight_class, distance, origin, destination


def format_datetime(dt):
    return dt.isoformat()


def data_to_write(untransformed):
  if untransformed['source_metadata']['is_deleted']:
    return {
      'id': untransformed['payload']['id'],
      'flight_date': None,
      'flight_number': None,
      'flight_class': None,
      'distance': None,
      'origin': None,
      'destination': None,
      'flow_card': None,
      'bag_checked': None,
      'meal_type': None,
      'change_type': untransformed['source_metadata']['change_type'],
      'read_timestamp': format_datetime(untransformed['read_timestamp']),
      'source_timestamp': format_datetime(untransformed['source_timestamp']),
    }
  flight_date, flight_number, flight_class, distance, origin, destination = split_flight_details(untransformed['payload']['flight_details'])
  return {
    'id': untransformed['payload']['id'],
    'flight_date': flight_date,
    'flight_number': flight_number,
    'flight_class': flight_class,
    'distance': distance,
    'origin': origin,
    'destination': destination,
    'flow_card': untransformed['payload']['flow_card'] == 1,
    'bag_checked': untransformed['payload']['bag_checked'],
    'meal_type': untransformed['payload']['meal_type'],
    'change_type': untransformed['source_metadata']['change_type'],
    'read_timestamp': format_datetime(untransformed['read_timestamp']),
    'source_timestamp': format_datetime(untransformed['source_timestamp'])
  }


def write_to_bigquery(data_to_write):
    client = bigquery.Client()
    dataset_ref = client.dataset(dataset_id="airline")
    table_ref = dataset_ref.table("airline_details")
    errors = client.insert_rows_json(table_ref, data_to_write)
    if errors:
        print("Encountered errors while inserting rows: {}".format(errors))
    else:
        print("Data inserted successfully.")


def read_gcs(blob_name):
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(blob_name)
    blob_bytes = blob.download_as_bytes()
    byte_stream = BytesIO(blob_bytes)
    reader = fastavro.reader(byte_stream)
    # Access individual records
    return [record for record in reader]

    

@functions_framework.cloud_event
def main(cloud_event) -> None:
    data = cloud_event.data

    name = data["name"]
    if ".avro" in name:
        print("File event", name)
        records = read_gcs(name)
        new_data = [data_to_write(record) for record in records]
        write_to_bigquery(new_data)
    else:
        print("Folder event, passing ...")