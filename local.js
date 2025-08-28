import * as http from 'node:http';

const server = http.createServer(async (req, res) => {
	console.log(`Received request for ${req.headers.host} from ${req.socket.remoteAddress}`);
	try {
		// Call service-b using Kubernetes in-cluster DNS
		const resp = await fetch('http://service-b.service-b-ns:8080');
		const data = await resp.json();

		res.writeHead(200, {'Content-Type': 'application/json'});
		const responseData = {
			message: `${data.message} and Hello from local service-a!`,
			path: req.url
		};
		res.end(JSON.stringify(responseData));
	} catch (error) {
		res.writeHead(500, {'Content-Type': 'application/json'});
		res.end(JSON.stringify({ error: 'service-b unavailable' }));
	}
});

server.listen(8080, '0.0.0.0', () => {
	console.log('Server running on port 8080');
});
