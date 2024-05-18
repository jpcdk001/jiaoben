import socket
import struct
import threading
import time
import atexit

import select
from flask import Flask, request, jsonify
from concurrent.futures import ThreadPoolExecutor

active_sockets = []
active_threads = []
sockets_lock = threading.Lock()
threads_lock = threading.Lock()
# 你原来的全局变量和函数
executor = ThreadPoolExecutor(max_workers=99)  # 允许的最大线程数

app = Flask(__name__)
proxy_status = 'off'


def set_proxy_status(status):
    global proxy_status
    proxy_status = status


# 新增的Flask路由
@app.route('/set_status', methods=['POST'])
def set_status():
    status = request.form.get('status')
    if status in ['on', 'off']:
        set_proxy_status(status)
        return jsonify({'status': 'success', 'message': f'Proxy set to {status}'}), 200
    else:
        return jsonify({'status': 'error', 'message': 'Invalid status'}), 400


def get_local_ip():
    try:
        local_ip = socket.gethostbyname(socket.gethostname())
        return local_ip
    except Exception as e:
        print(f"Unable to get local IP: {e}")
        return None


def handle_client(client_socket):
    # Receive the SOCKS5 method selection message
    method_selection_msg = receive_all(client_socket, 2)
    if method_selection_msg is None:
        client_socket.close()
        return
    version, nmethods = struct.unpack('!BB', method_selection_msg)

    # Receive the list of methods
    methods = receive_all(client_socket, nmethods)
    if methods is None:
        client_socket.close()
        return

    # Check the methods and select a method (in this case, we select 'no authentication')
    if 0 not in methods:
        # No acceptable methods
        response = struct.pack('!BB', 5, 0xFF)
        client_socket.sendall(response)
        client_socket.close()
        return
    else:
        # 'No authentication' is acceptable
        response = struct.pack('!BB', 5, 0)
        client_socket.sendall(response)

        header = receive_all(client_socket, 4)
        if header is None:
            client_socket.close()
            return

        version, command, _, address_type = struct.unpack('!BBBB', header)
        if command != 1:  # Only CONNECT is supported
            client_socket.close()
            return

        if address_type == 1:  # IPv4 address
            address = receive_all(client_socket, 4)
            if address is None:
                client_socket.close()
                return
            target_address = socket.inet_ntoa(address)
        elif address_type == 3:  # Domain name
            length = receive_all(client_socket, 1)
            if length is None:
                client_socket.close()
                return
            address = receive_all(client_socket, length[0])
            if address is None:
                client_socket.close()
                return
            target_address = address.decode('utf-8')
        else:  # Unsupported address type
            client_socket.close()
            return

        port = receive_all(client_socket, 2)
        if port is None:
            client_socket.close()
            return
        target_port = int.from_bytes(port, 'big')

        # Connect to the target server and send the response
        try:
            server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server_socket.connect((target_address, target_port))

            # Send a successful response
            response = struct.pack('!BBBBIH', 5, 0, 0, 1, 0, 0)
            client_socket.sendall(response)
        except Exception:
            # Send a failed response
            response = struct.pack('!BBBBIH', 5, 1, 0, 1, 0, 0)
            client_socket.sendall(response)
            client_socket.close()
            return

        # 数据转发
        # Data forwarding
        def forward(source, destination):
            try:
                while True:
                    data = source.recv(4096)
                    if len(data) == 0:
                        break
                    while len(data) > 0:
                        sent = destination.send(data)
                        data = data[sent:]
            except socket.error as e:
                        pass
            except Exception as e:
                        pass
            finally:
                # 确保即使出现异常也关闭套接字
                source.close()
                destination.close()
                with sockets_lock:
                    if source in active_sockets:
                        active_sockets.remove(source)
                    if destination in active_sockets:
                        active_sockets.remove(destination)

        # 设置非阻塞
        client_socket.setblocking(False)
        server_socket.setblocking(False)
        client_socket.settimeout(30)  # 设置超时时间，例如30秒

        # 修改 forward 函数调用，使用非阻塞版本
        client_to_server = threading.Thread(target=forward_nonblocking, args=(client_socket, server_socket))
        server_to_client = threading.Thread(target=forward_nonblocking, args=(server_socket, client_socket))

        with sockets_lock:
            active_sockets.append(client_socket)
            active_sockets.append(server_socket)

        client_to_server.start()
        server_to_client.start()

        with threads_lock:
            active_threads.append(client_to_server)
            active_threads.append(server_to_client)

        # Wait for both threads to finish
        client_to_server.join()
        server_to_client.join()

        with threads_lock:
            if client_to_server in active_threads:
                active_threads.remove(client_to_server)
            if server_to_client in active_threads:
                active_threads.remove(server_to_client)


def forward_nonblocking(source, destination):
    while True:
        try:
            read_ready, _, _ = select.select([source], [], [], 0.1)
            if read_ready:
                data = source.recv(4096)
                if not data:
                    break
                destination.sendall(data)
        except Exception as e:
            print(f"Exception in forwarding: {e}")
            break
    source.close()
    destination.close()


def receive_all(sock, length):
    data = b""
    while len(data) < length:
        packet = sock.recv(length - len(data))
        if not packet:
            return None
        data += packet
    return data


def start_proxy():
    # 创建监听套接字
    proxy_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    proxy_socket.bind(('0.0.0.0', 5209))  # 监听所有网络接口的5209端口
    proxy_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    proxy_socket.listen(10)

    while True:
        if proxy_status == 'on':
            print('开启状态')
            client_socket, client_addr = proxy_socket.accept()
            print('接受来自', client_addr, '的连接')
            executor.submit(handle_client, client_socket)  # 使用线程池处理连接
        elif proxy_status == 'off':
            time.sleep(2)
            print('关闭状态')
        else:
            print("未知的代理状态:", proxy_status)


def cleanup():
    for sock in active_sockets:
        try:
            sock.close()
        except Exception:
            pass

    for thread in active_threads:
        try:
            thread.join()
        except Exception:
            pass


atexit.register(cleanup)

if __name__ == '__main__':
    flask_thread = threading.Thread(target=app.run, kwargs={'host': '0.0.0.0', 'port': 3389})
    flask_thread.start()
    start_proxy()
