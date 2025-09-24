defmodule TenbinCache.DNSTestHelper do
  @moduledoc """
  Common test helper functions for DNS packet creation and manipulation.
  This module provides reusable utilities to reduce code duplication across test files.
  """

  @doc """
  Creates a test DNS packet for "example.com" A record query.

  Returns a binary DNS packet suitable for testing DNS processing functions.
  """
  def create_test_dns_packet do
    # Create a simple DNS query packet for testing
    # This is a manually crafted DNS query for "example.com" A record
    <<
      # Header
      # Transaction ID (12345)
      0x30,
      0x39,
      # Flags: QR=0, Opcode=0, AA=0, TC=0, RD=1, RA=0, Z=0, RCODE=0
      0x01,
      0x00,
      # QDCOUNT: 1 question
      0x00,
      0x01,
      # ANCOUNT: 0 answers
      0x00,
      0x00,
      # NSCOUNT: 0 authority records
      0x00,
      0x00,
      # ARCOUNT: 0 additional records
      0x00,
      0x00,

      # Question section
      # 7-byte label "example"
      0x07,
      "example",
      # 3-byte label "com"
      0x03,
      "com",
      # Root label (end of domain name)
      0x00,
      # QTYPE: A record (1)
      0x00,
      0x01,
      # QCLASS: IN (1)
      0x00,
      0x01
    >>
  end

  @doc """
  Creates a large DNS packet for testing buffer limits.

  Returns a binary DNS packet that is close to typical UDP buffer limits
  but still valid for testing large packet handling.
  """
  def create_large_dns_packet do
    # Base packet header (same as create_test_dns_packet)
    header = <<
      0x30, 0x39,  # Transaction ID (12345)
      0x01, 0x00,  # Flags
      0x00, 0x01,  # QDCOUNT: 1 question
      0x00, 0x00,  # ANCOUNT: 0 answers
      0x00, 0x00,  # NSCOUNT: 0 authority records
      0x00, 0x00   # ARCOUNT: 0 additional records
    >>

    # Create a long domain name to make the packet larger
    # Use multiple labels to create a long but valid domain
    long_domain_labels = Enum.map(1..20, fn i ->
      label = "label#{i}"
      <<byte_size(label)>> <> label
    end)

    long_domain = Enum.join(long_domain_labels, "") <> <<0x00>>  # Root label

    # Question section with long domain
    question = long_domain <> <<0x00, 0x01, 0x00, 0x01>>  # QTYPE: A, QCLASS: IN

    header <> question
  end

  @doc """
  Creates a portable invalid directory path for testing error handling.

  This function creates a directory path that will reliably cause
  permission errors across different operating systems.
  """
  def create_invalid_directory_path do
    # Create a temporary file where a directory should be
    # This will cause directory creation to fail portably
    invalid_base = System.tmp_dir!()
    invalid_file = Path.join(invalid_base, "test_file_not_dir")

    # Ensure the file exists
    File.write!(invalid_file, "test content")

    # Return path that treats the file as if it were a directory
    # This will fail on all operating systems
    Path.join(invalid_file, "subdirectory")
  end

  @doc """
  Creates a directory-based file access error for testing.

  Instead of using file permissions (which may not work in all environments),
  this creates a directory where a file is expected, causing a reliable
  access error across all platforms.
  """
  def create_file_access_error_scenario do
    # Create a temporary directory structure
    base_dir = Path.join(System.tmp_dir!(), "tenbin_test_#{:rand.uniform(10000)}")
    file_path = Path.join(base_dir, "config.yaml")

    # Create the directory structure
    File.mkdir_p!(base_dir)

    # Create a directory where a file should be (causes read error)
    File.mkdir_p!(file_path)

    {base_dir, file_path}
  end

  @doc """
  Cleans up test files and directories created by helper functions.
  """
  def cleanup_test_files(paths) when is_list(paths) do
    Enum.each(paths, &cleanup_test_files/1)
  end

  def cleanup_test_files(path) when is_binary(path) do
    if File.exists?(path) do
      File.rm_rf!(path)
    end
  end
end