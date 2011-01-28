#############################################################################
# Copyright © 2010 Dan Wanek <dan.wanek@gmail.com>
#
#
# This file is part of the Ruby GSSAPI library.
# 
# GSSAPI is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
# 
# GSSAPI is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
# Public License for more details.
# 
# You should have received a copy of the GNU General Public License along
# with GSSAPI.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################
module GSSAPI

  # This class is a simple wrapper around the most common usage of GSSAPI. If you are looking at doing
  #   something a bit more advanced you may want to check out the LibGSSAPI module.
  class Simple

    attr_reader :context

    # Initialize a new GSSAPI::Simple object
    # @param [String] host_name the fully qualified host name
    # @param [String] service_name the service name. This can either be in the form svc@example.org 
    #   or just svc.  If there is no '@example.org' part the host_name will be appended. If no
    #   service_name is given at all the default service of 'host' will be used.
    def initialize(host_name, service_name=nil, keytab=nil)
      @host = host_name
      @service = service_name.nil? ? "host@#{@host}" : (service_name.include?('@') ? service_name : "#{service_name}@#{@host}")
      @int_svc_name = import_name(@service)
      @context = nil # the security context
      @scred = nil # the service credentials.  really only used for the server-side via acquire_credentials
      set_keytab(keytab) unless keytab.nil?
    end


    # Convert a String to a GSSAPI usable buffer (gss_buffer_desc)
    # @param [String] str the string to convert
    def import_name(str)
      buff_str = LibGSSAPI::GssBufferDesc.new
      buff_str.value = str
      mech = LibGSSAPI::GssOID.gss_c_no_oid
      #mech = LibGSSAPI.GSS_C_NT_HOSTBASED_SERVICE
      name = FFI::MemoryPointer.new :pointer # gss_name_t
      min_stat = FFI::MemoryPointer.new :uint32

      maj_stat = LibGSSAPI.gss_import_name(min_stat, buff_str.pointer, mech, name)
      raise GssApiError, "gss_import_name did not return GSS_S_COMPLETE.  Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat != 0

      LibGSSAPI::GssNameT.new(name.get_pointer(0))
    end

    # Initialize the GSS security context (client initiator).  If there was a previous call that issued a
    #   continue you can pass the continuation token in via the token param.
    #   If no flags are set the default flags are LibGSSAPI::GSS_C_MUTUAL_FLAG | LibGSSAPI::GSS_C_SEQUENCE_FLAG
    # @param [String] in_token an input token sent from the remote service in a continuation.
    # @param [Hash] opts misc opts to be set
    # @option opts [Fixnum] :flags override all other flags.  If you set the :delegate option this option will override it.
    #   @see http://tools.ietf.org/html/rfc4121#section-4.1.1.1
    # @option opts [Boolean] :delegate if true set the credential delegate flag
    # @return [String, true] if a continuation flag is set it will return the output token that is needed to send
    #   to the remote host.  Otherwise it returns true and the GSS security context has been established.
    def init_context(in_token = nil, opts = {})
      min_stat = FFI::MemoryPointer.new :uint32
      ctx = (@context.nil? ? LibGSSAPI::GssCtxIdT.gss_c_no_context.address_of : @context.address_of)
      mech = LibGSSAPI::GssOID.gss_c_no_oid
      if(opts[:flags])
        flags = opts[:flags]
      else
        flags = (LibGSSAPI::GSS_C_MUTUAL_FLAG | LibGSSAPI::GSS_C_SEQUENCE_FLAG)
        flags |= LibGSSAPI::GSS_C_DELEG_FLAG  if opts[:delegate]
        flags |= LibGSSAPI::GSS_C_DELEG_POLICY_FLAG  if opts[:delegate]
      end
      in_tok = LibGSSAPI::GssBufferDesc.new
      in_tok.value = in_token
      out_tok = LibGSSAPI::GssBufferDesc.new
      out_tok.value = nil
      ret_flags = FFI::MemoryPointer.new :uint32


      maj_stat = LibGSSAPI.gss_init_sec_context(min_stat,
                                                nil,
                                                ctx,
                                                @int_svc_name,
                                                mech,
                                                flags,
                                                0,
                                                nil,
                                                in_tok.pointer,
                                                nil,
                                                out_tok.pointer,
                                                ret_flags,
                                                nil)

      raise GssApiError, "gss_init_sec_context did not return GSS_S_COMPLETE.  Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat > 1
      
      @context = LibGSSAPI::GssCtxIdT.new(ctx.get_pointer(0))
      maj_stat == 1 ? out_tok.value : true
    end


    # Accept a security context that was initiated by a remote peer.
    # @param [String] in_token The token sent by the remote client to initiate the context
    # @return [String, true] If this is part of a continuation it will return a token to be passed back to the remote
    #   otherwise it will simply return true.
    def accept_context(in_token)
      raise GssApiError, "No credentials yet acquired. Call #{self.class.name}#acquire_credentials first" if @scred.nil?

      min_stat = FFI::MemoryPointer.new :uint32
      ctx = (@context.nil? ? LibGSSAPI::GssCtxIdT.gss_c_no_context.address_of : @context.address_of)
      no_chn_bind = LibGSSAPI::GSS_C_NO_CHANNEL_BINDINGS
      client = FFI::MemoryPointer.new :pointer  # Will hold the initiating client name after the call
      mech = FFI::MemoryPointer.new :pointer  # Will hold the mech being used after the call
      in_tok = GSSAPI::LibGSSAPI::GssBufferDesc.new
      in_tok.value = in_token
      out_tok = GSSAPI::LibGSSAPI::GssBufferDesc.new
      out_tok.value = nil 
      ret_flags = FFI::MemoryPointer.new :uint32

      maj_stat = LibGSSAPI.gss_accept_sec_context(min_stat,
                                                  ctx,
                                                  @scred,
                                                  in_tok.pointer,
                                                  no_chn_bind,
                                                  client,
                                                  mech,
                                                  out_tok.pointer,
                                                  ret_flags,
                                                  nil, nil)

      raise GssApiError, "gss_accept_sec_context did not return GSS_S_COMPLETE.  Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat > 1

      @context = LibGSSAPI::GssCtxIdT.new(ctx.get_pointer(0))
      out_tok.length > 0 ? out_tok.value : true
    end


    # Acquire security credentials. This does not log you in. It grabs the credentials from a cred cache or keytab.
    # @param [Hash] opts options to pass to the gss_acquire_cred function.
    # @option opts [String] :usage The credential usage type (:accept, :initiate, :both).  It defaults to 'accept' since
    #   this method is most usually called on the server only.
    # @return [true] It will return true if everything succeeds and the @scred variable will be set for future methods. If
    #   an error ocurrs an exception will be raised.
    def acquire_credentials(princ = @int_svc_name, opts = {:usage => :accept})
      min_stat = FFI::MemoryPointer.new :uint32
      scred = FFI::MemoryPointer.new :pointer

      case opts[:usage]
      when :accept
        usage = LibGSSAPI::GSS_C_ACCEPT
      when :initiate
        usage = LibGSSAPI::GSS_C_INITIATE
      when :both
        usage = LibGSSAPI::GSS_C_BOTH
      else
        raise GssApiError, "Bad option passed to #{self.class.name}#acquire_credentials"
      end

      maj_stat = LibGSSAPI.gss_acquire_cred(min_stat, princ, 0, LibGSSAPI::GSS_C_NO_OID_SET, usage, scred, nil, nil)
      raise GssApiError, "gss_acquire_cred did not return GSS_S_COMPLETE.  Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat != 0

      @scred = LibGSSAPI::GssCredIdT.new(scred.get_pointer(0))
      true
    end

    # Wrap a message using gss_wrap. It can either encrypt the message (confidentiality) or simply sign it (integrity).
    # @param [String] msg The message to wrap
    # @param [Boolean] encrypt Whether or not to encrypt the message or just sign it.  The default is to encrypt.
    # @return [String] The wrapped message. It will raise an exception on error
    def wrap_message(msg, encrypt = true)
      min_stat = FFI::MemoryPointer.new :uint32
      conf_req = (encrypt ? 1 : 0)
      qop_req = GSSAPI::LibGSSAPI::GSS_C_QOP_DEFAULT
      in_buff = GSSAPI::LibGSSAPI::GssBufferDesc.new
      in_buff.value = msg
      conf_state = FFI::MemoryPointer.new :uint32
      out_buff = GSSAPI::LibGSSAPI::GssBufferDesc.new
      out_buff.value = nil
      maj_stat = GSSAPI::LibGSSAPI.gss_wrap(min_stat, @context, conf_req, qop_req, in_buff.pointer, conf_state, out_buff.pointer)
      raise GssApiError, "Failed to gss_wrap message. Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat != 0
      out_buff.value
    end

    # Unwrap a message previously wrapped with gss_wrap.
    # @param [String] msg The message to unwrap
    # @param [Boolean] encrypted Whether or not this message was encrypted (true) or just signed (false)
    def unwrap_message(msg, encrypted = true)
      min_stat = FFI::MemoryPointer.new :uint32
      in_buff = GSSAPI::LibGSSAPI::GssBufferDesc.new
      in_buff.value = msg
      out_buff = GSSAPI::LibGSSAPI::GssBufferDesc.new
      conf_state = FFI::MemoryPointer.new :int
      conf_state.write_int((encrypted ? 1 : 0))
      q_op = FFI::MemoryPointer.new :uint32
      q_op.write_int(0)
      maj_stat = GSSAPI::LibGSSAPI.gss_unwrap(min_stat, @context, in_buff.pointer, out_buff.pointer, conf_state, q_op)
      raise GssApiError, "Failed to gss_unwrap message. Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat != 0
      out_buff.value
    end

    # Add a path to a custom keytab file
    # @param [String] keytab the path to the keytab
    def set_keytab(keytab)
      maj_stat = LibGSSAPI.krb5_gss_register_acceptor_identity(keytab)
      raise GssApiError, "krb5_gss_register_acceptor_identity did not return GSS_S_COMPLETE.  Error code: maj: #{maj_stat}, min: #{min_stat.read_int}" if maj_stat != 0
      true
    end

  end # Simple
end # GSSAPI
