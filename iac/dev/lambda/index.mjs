export async function handler(event) {
  const body = event.isBase64Encoded
    ? Buffer.from(event.body, 'base64').toString('utf-8')
    : event.body;

  try {
    const response = await fetch(
      `http://${process.env.OPENEMS_HOST}:8082/jsonrpc`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Basic ${process.env.OPENEMS_B2B_CREDS}`
        },
        body
      }
    );
    return {
      statusCode: response.status,
      headers: { 'Content-Type': 'application/json' },
      isBase64Encoded: false,
      body: await response.text()
    };
  } catch (err) {
    return {
      statusCode: 502,
      headers: { 'Content-Type': 'application/json' },
      isBase64Encoded: false,
      body: JSON.stringify({
        error: { message: 'Backend unreachable', code: 'PROXY_BACKEND_UNREACHABLE' }
      })
    };
  }
}
