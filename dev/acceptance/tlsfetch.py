"""Fetch a URL with certificate verification pinned to one root CA.

Used instead of curl because Windows curl builds use schannel, which applies its own revocation
policy to a private CA and reports "revocation status is unknown". Verification here is explicit
and identical on every platform: the peer certificate must chain to --cacert and match the URL
hostname. --override-ip changes only the address that is opened; the URL hostname still governs
SNI, name matching, and the Host header, so nothing about verification is relaxed.

Usage:
  python tlsfetch.py URL --cacert ROOT.PEM [--override-ip 10.0.0.5] [--method GET|HEAD]
                         [--out FILE] [--require-header Replay-Nonce]
Exit code 0 only for a 2xx response whose TLS peer verified.
"""
import argparse
import http.client
import socket
import ssl
import sys
import urllib.parse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--cacert", required=True)
    parser.add_argument("--override-ip", default=None,
                        help="connect to this address while still verifying the URL hostname")
    parser.add_argument("--method", default="GET", choices=["GET", "HEAD"])
    parser.add_argument("--out", default=None)
    parser.add_argument("--require-header", default=None,
                        help="fail unless the response carries this header (case-insensitive)")
    parser.add_argument("--peek", action="store_true",
                        help="complete the TLS handshake, write the peer certificate DER to --out, send no request")
    args = parser.parse_args()

    url = urllib.parse.urlparse(args.url)
    if url.scheme not in ("https", "http"):
        print(f"unsupported scheme {url.scheme!r}", file=sys.stderr)
        return 2
    if url.scheme == "http" and url.hostname not in ("127.0.0.1", "localhost", "::1"):
        print("refusing plain http to a non-loopback host", file=sys.stderr)
        return 2

    host = url.hostname
    port = url.port or (443 if url.scheme == "https" else 80)
    path = (url.path or "/") + (("?" + url.query) if url.query else "")
    address = args.override_ip or host
    client = http.client.HTTPConnection(host, port, timeout=20)
    try:
        stream = socket.create_connection((address, port), timeout=20)
        if url.scheme == "https":
            stream = ssl.create_default_context(cafile=args.cacert).wrap_socket(stream, server_hostname=host)
        if args.peek:
            der = stream.getpeercert(binary_form=True)
            stream.close()
            if not der:
                print("the peer presented no certificate", file=sys.stderr)
                return 1
            if not args.out:
                print("--peek writes the peer certificate to --out; no --out was given", file=sys.stderr)
                return 2
            open(args.out, "wb").write(der)
            return 0
        client.sock = stream
        client.request(args.method, path)
        response = client.getresponse()
        body = response.read()
    except ssl.SSLCertVerificationError as error:
        print(f"TLS verification against {args.cacert} failed: {error}", file=sys.stderr)
        return 1
    except (OSError, http.client.HTTPException) as error:
        print(f"request to {args.url} failed: {error}", file=sys.stderr)
        return 1
    finally:
        client.close()

    if not 200 <= response.status < 300:
        print(f"{args.url} returned HTTP {response.status}", file=sys.stderr)
        return 1
    if args.require_header and not any(name.lower() == args.require_header.lower() for name in response.headers):
        print(f"response is missing the {args.require_header} header", file=sys.stderr)
        return 1
    if args.out:
        with open(args.out, "wb") as stream:
            stream.write(body)
    else:
        sys.stdout.buffer.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
