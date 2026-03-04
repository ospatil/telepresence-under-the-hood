import * as http from 'node:http';

const server = http.createServer(async (req, res) => {
	console.log(`Received request for ${req.headers.host} from ${req.socket.remoteAddress}`);
	try {
		const resp = await fetch('http://service-d.service-d-ns:8080');
		const data = await resp.json();

		res.writeHead(200, {'Content-Type': 'application/json'});
		const responseData = {
			message: `${data.message} and Hello from local service-c!`,
			path: req.url
		};
		console.log('Done processing, Response:', responseData)
		res.end(JSON.stringify(responseData));
	} catch (error) {
		res.writeHead(500, {'Content-Type': 'application/json'});
		res.end(JSON.stringify({ error: 'service-d unavailable' }));
	}
});

server.listen(8080, '0.0.0.0', () => {
	console.log('Server running on port 8080');
});
