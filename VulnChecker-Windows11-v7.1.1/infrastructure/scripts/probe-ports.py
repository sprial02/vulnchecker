import socket
import argparse
parser = argparse.ArgumentParser(description='Check SSH and Windows remoting TCP ports')
parser.add_argument('host')
args = parser.parse_args()
for port in (5985, 5986, 22):
    with socket.socket() as connection:
        connection.settimeout(3)
        print(f'{args.host}:{port}:', 'open' if connection.connect_ex((args.host, port)) == 0 else 'closed/unreachable')
