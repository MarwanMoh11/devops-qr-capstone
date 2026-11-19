'use client'

import { useState } from 'react';

function errorMessage(status, data) {
  if (status === 422) return 'Please enter a valid http(s) URL, such as https://example.com.';
  if (status === 502 || status === 503) return 'The QR service is unavailable right now. Please try again.';
  if (typeof data?.detail === 'string') return data.detail;
  return `Something went wrong (HTTP ${status}).`;
}

export default function Home() {
  const [url, setUrl] = useState('');
  const [qrCodeUrl, setQrCodeUrl] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setError('');
    setQrCodeUrl('');
    try {
      const response = await fetch('/api/qr', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ url }),
      });
      const data = await response.json().catch(() => ({}));
      if (response.status === 201 && data.image_url) {
        setQrCodeUrl(data.image_url);
      } else {
        setError(errorMessage(response.status, data));
      }
    } catch {
      setError('Could not reach the server. Check your connection and try again.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={styles.container}>
      <h1 style={styles.title}>QR Code Generator</h1>
      <form onSubmit={handleSubmit} style={styles.form}>
        <input
          type="text"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="Enter URL like https://example.com"
          aria-label="URL"
          style={styles.input}
        />
        <button type="submit" disabled={loading} style={styles.button}>
          {loading ? 'Generating…' : 'Generate QR Code'}
        </button>
      </form>
      {error && <p role="alert" style={styles.error}>{error}</p>}
      {qrCodeUrl && (
        // eslint-disable-next-line @next/next/no-img-element -- served by our own /api/qr proxy
        <img src={qrCodeUrl} alt="QR Code" style={styles.qrCode} />
      )}
    </div>
  );
}

// Styles
const styles = {
  container: {
    minHeight: '100vh',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#121212',
    color: 'white',
  },
  title: {
    margin: '0',
    lineHeight: '1.15',
    fontSize: '4rem',
    textAlign: 'center',
  },
  form: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
  },
  input: {
    padding: '10px',
    borderRadius: '5px',
    border: 'none',
    marginTop: '20px',
    width: '300px',
    color: '#121212'

  },
  button: {
    padding: '10px 20px',
    marginTop: '20px',
    border: 'none',
    borderRadius: '5px',
    backgroundColor: '#0070f3',
    color: 'white',
    cursor: 'pointer',
  },
  error: {
    marginTop: '20px',
    color: '#ff6b6b',
  },
  qrCode: {
    marginTop: '20px',
  },
};
