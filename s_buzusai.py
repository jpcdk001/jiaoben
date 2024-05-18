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
MAX_CONNECTIONS = 100  # 可以根据实际情况调整

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
    try:
        # 进行SOCKS5握手
        method_selection_msg = receive_all(client_socket, 2)
        if method_selection_msg is None:
            client_socket.close()
            return
        version, nmethods = struct.unpack('!BB', method_selection_msg)

        methods = receive_all(client_socket, nmethods)
        if methods is None:
            client_socket.close()
            return

        if 0 not in methods:
            response = struct.pack('!BB', 5, 0xFF)
            client_socket.sendall(response)
            client_socket.close()
            return
        else:
            response = struct.pack('!BB', 5, 0)
            client_socket.sendall(response)

            header = receive_all(client_socket, 4)
            if header is None:
                client_socket.close()
                return

            version, command, _, address_type = struct.unpack('!BBBB', header)
            if command != 1:
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
            else:
                client_socket.close()
                return

            port = receive_all(client_socket, 2)
            if port is None:
                client_socket.close()
                return
            target_port = int.from_bytes(port, 'big')

            # 连接到目标服务器
            try:
                server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                server_socket.connect((target_address, target_port))
                response = struct.pack('!BBBBIH', 5, 0, 0, 1, 0, 0)
                client_socket.sendall(response)
            except Exception:
                response = struct.pack('!BBBBIH', 5, 1, 0, 1, 0, 0)
                client_socket.sendall(response)
                client_socket.close()
                return

            # 设置套接字为非阻塞
            client_socket.setblocking(0)
            server_socket.setblocking(0)

            # 使用select处理套接字
            manage_sockets(client_socket, server_socket)

    finally:
        # 清理工作
        cleanup_sockets(client_socket, server_socket)

# 以下是新添加的辅助函数
def manage_sockets(client_socket, server_socket):
    sockets = [client_socket, server_socket]
    while True:
        readable, _, exceptional = select.select(sockets, [], sockets, 0.1)
        for s in readable:
            if s is client_socket:
                data = client_socket.recv(4096)
                if data:
                    server_socket.sendall(data)
                else:
                    return  # 客户端关闭连接
            elif s is server_socket:
                data = server_socket.recv(4096)
                if data:
                    client_socket.sendall(data)
                else:
                    return  # 服务器关闭连接

        for s in exceptional:
            return  # 发生异常

def cleanup_sockets(client_socket, server_socket):
    client_socket.close()
    server_socket.close()
    with sockets_lock:
        if client_socket in active_sockets:
            active_sockets.remove(client_socket)
        if server_socket in active_sockets:
            active_sockets.remove(server_socket)

def forward_nonblocking(source, destination):
    source.setblocking(False)
    destination.setblocking(False)
    while True:
        try:
            data = source.recv(4096)
            if not data:
                break
            sent = destination.send(data)

            time.sleep(0.01)
        except Exception as e:
            if destination.fileno() == -1:  # The socket is closed
                print('Socket is already closed')
            else:
                raise e  # The exception is not because the socket is closed
    # 当源断开或者发送数据出错时，关闭两个连接
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
            if len(active_sockets) < MAX_CONNECTIONS:
                try:
                    client_socket, client_addr = proxy_socket.accept()
                    executor.submit(handle_client, client_socket)
                    with sockets_lock:
                        active_sockets.append(client_socket)
                except BlockingIOError:
                    time.sleep(0.01)
            else:
                print("达到最大连接数，暂时不接受新连接")
                time.sleep(1)  # 简单的节流控制
        elif proxy_status == 'off':
            time.sleep(1)
        else:
            print("未知的代理状态:", proxy_status)
            time.sleep(1)


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
