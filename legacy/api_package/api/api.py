from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, IPv4Address, IPv6Address
import mysql.connector
from pathlib import Path

app = FastAPI()

RR_CONFIG_DIR = "/etc/bird/rr"
DB_CONFIG = {
    'host': 'localhost',
    'user': 'bird_api',
    'password': 'yourpassword',
    'database': 'routing'
}

class SetRouteRequest(BaseModel):
    ipv4: IPv4Address
    ipv6: IPv6Address

class RemoveRouteRequest(BaseModel):
    ipv4: IPv4Address
    ipv6: IPv6Address

def get_db_connection():
    return mysql.connector.connect(**DB_CONFIG)

@app.get("/allowed/{ipv6}")
def get_allowed_ipv4(ipv6: IPv6Address):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT ipv4 FROM allowed_routes WHERE ipv6 = %s", (str(ipv6),))
    rows = cursor.fetchall()
    conn.close()
    return [row[0] for row in rows]

@app.post("/set-route")
def set_route(data: SetRouteRequest):
    allowed = get_allowed_ipv4(data.ipv6)
    if str(data.ipv4) not in allowed:
        raise HTTPException(status_code=403, detail="This IPv6 is not allowed to set route for this IPv4")

    route_file = Path(RR_CONFIG_DIR) / f"{data.ipv4}.conf"
    with open(route_file, 'w') as f:
        f.write(f'route {data.ipv4}/32 via "{data.ipv6}";\n')

    return {"status": "ok", "message": f"Set {data.ipv4} via {data.ipv6}"}

@app.post("/remove-route")
def remove_route(data: RemoveRouteRequest):
    route_file = Path(RR_CONFIG_DIR) / f"{data.ipv4}.conf"
    if route_file.exists():
        with open(route_file, 'r') as f:
            contents = f.read()
            if str(data.ipv6) not in contents:
                raise HTTPException(status_code=403, detail="This IPv6 is not the current next hop")

        route_file.unlink()
        return {"status": "ok", "message": f"Removed route for {data.ipv4}"}
    else:
        raise HTTPException(status_code=404, detail="Route file does not exist")
