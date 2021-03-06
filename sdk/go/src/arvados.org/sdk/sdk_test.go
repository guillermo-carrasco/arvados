package sdk

import (
	"fmt"
	. "gopkg.in/check.v1"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Gocheck boilerplate
func Test(t *testing.T) {
	TestingT(t)
}

var _ = Suite(&ServerRequiredSuite{})

// Tests that require the Keep server running
type ServerRequiredSuite struct{}

func pythonDir() string {
	gopath := os.Getenv("GOPATH")
	return fmt.Sprintf("%s/../python/tests", strings.Split(gopath, ":")[0])
}

func (s *ServerRequiredSuite) SetUpSuite(c *C) {
	os.Chdir(pythonDir())
	if err := exec.Command("python", "run_test_server.py", "start").Run(); err != nil {
		panic("'python run_test_server.py start' returned error")
	}
	if err := exec.Command("python", "run_test_server.py", "start_keep").Run(); err != nil {
		panic("'python run_test_server.py start_keep' returned error")
	}
}

func (s *ServerRequiredSuite) TestMakeArvadosClient(c *C) {
	os.Setenv("ARVADOS_API_HOST", "localhost:3001")
	os.Setenv("ARVADOS_API_TOKEN", "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")
	os.Setenv("ARVADOS_API_HOST_INSECURE", "")

	kc, err := MakeArvadosClient()
	c.Check(kc.ApiServer, Equals, "localhost:3001")
	c.Check(kc.ApiToken, Equals, "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")
	c.Check(kc.ApiInsecure, Equals, false)

	os.Setenv("ARVADOS_API_HOST_INSECURE", "true")

	kc, err = MakeArvadosClient()
	c.Check(kc.ApiServer, Equals, "localhost:3001")
	c.Check(kc.ApiToken, Equals, "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")
	c.Check(kc.ApiInsecure, Equals, true)
	c.Check(kc.Client.Transport.(*http.Transport).TLSClientConfig.InsecureSkipVerify, Equals, true)

	c.Assert(err, Equals, nil)
}

func (s *ServerRequiredSuite) TestCreatePipelineTemplate(c *C) {
	os.Setenv("ARVADOS_API_HOST", "localhost:3001")
	os.Setenv("ARVADOS_API_TOKEN", "4axaw8zxe0qm22wa6urpp5nskcne8z88cvbupv653y1njyi05h")
	os.Setenv("ARVADOS_API_HOST_INSECURE", "true")

	arv, err := MakeArvadosClient()

	getback := make(Dict)
	err = arv.Create("pipeline_templates",
		Dict{"pipeline_template": Dict{
			"name": "tmp",
			"components": Dict{
				"c1": map[string]string{"script": "script1"},
				"c2": map[string]string{"script": "script2"}}}},
		&getback)
	c.Assert(err, Equals, nil)
	c.Assert(getback["name"], Equals, "tmp")
	c.Assert(getback["components"].(map[string]interface{})["c2"].(map[string]interface{})["script"], Equals, "script2")

	uuid := getback["uuid"].(string)
	getback = make(Dict)
	err = arv.Update("pipeline_templates", uuid,
		Dict{
			"pipeline_template": Dict{"name": "tmp2"}},
		&getback)
	c.Assert(err, Equals, nil)
	c.Assert(getback["name"], Equals, "tmp2")

	c.Assert(getback["uuid"].(string), Equals, uuid)
	getback = make(Dict)
	err = arv.Delete("pipeline_templates", uuid, nil, &getback)
	c.Assert(err, Equals, nil)
	c.Assert(getback["name"], Equals, "tmp2")
}
